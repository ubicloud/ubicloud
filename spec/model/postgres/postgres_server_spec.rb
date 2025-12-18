# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresServer do
  subject(:postgres_server) {
    described_class.create(
      timeline:, resource:, vm_id: vm.id, representative_at: Time.now,
      synchronization_status: "ready", timeline_access: "push", version: "16"
    )
  }

  let(:project) { Project.create(name: "postgres-server") }
  let(:project_service) { Project.create(name: "postgres-service") }

  let(:timeline) { PostgresTimeline.create(location:) }

  let(:resource) {
    PostgresResource.create(
      name: "postgres-resource",
      project:,
      location:,
      ha_type: PostgresResource::HaType::NONE,
      user_config: {},
      pgbouncer_user_config: {},
      target_version: "16",
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
      superuser_password: "super"
    )
  }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "postgres-subnet", project:, location:,
      net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
      net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64")
    )
  }

  let(:vm) { create_hosted_vm(project, private_subnet, "dummy-vm") }

  let(:location) {
    Location.create(
      name: "us-west-2",
      project:,
      display_name: "us-west-2",
      ui_name: "us-west-2",
      provider: "ubicloud",
      visible: true
    )
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(project_service.id)
  end

  def create_postgres_resource(name, **overrides)
    PostgresResource.create({
      name:, project:, location:,
      ha_type: PostgresResource::HaType::NONE,
      user_config: {}, pgbouncer_user_config: {},
      target_version: "16", target_vm_size: "standard-2", target_storage_size_gib: 64,
      superuser_password: "super"
    }.merge(overrides))
  end

  def create_failover_server(prefix:, label:, vm_size: "standard-2")
    server_vm = create_hosted_vm(project, private_subnet, "#{prefix}-#{SecureRandom.hex(4)}")
    family, vcpus = vm_size.split("-")
    server_vm.update(family:, vcpus: vcpus.to_i, arch: "x64", cpu_percent_limit: nil)
    VmStorageVolume.create(vm: server_vm, disk_index: 0, boot: false, size_gib: 64)
    server = described_class.create(
      timeline:, resource:, vm_id: server_vm.id,
      synchronization_status: "ready", timeline_access: "fetch", version: "16"
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label:)
    server
  end

  def stub_current_lsn(lsn_by_id)
    resource.servers.each do |s|
      next unless (lsn = lsn_by_id[s.id])
      expect(s.vm.sshable).to receive(:_cmd).and_return(lsn)
    end
  end

  def down_pulse
    {reading: "down", reading_rpt: 5, reading_chg: Time.now - 30}
  end

  def check_pulse_session(db_connection: DB)
    {ssh_session: Net::SSH::Connection::Session.allocate, db_connection:}
  end

  describe "#configure" do
    before do
      resource.update(flavor: PostgresResource::Flavor::STANDARD, cert_auth_users: [])
      MinioCluster.create(
        project_id: Config.postgres_service_project_id, location:, name: "pgminio", admin_user: "root", admin_password: "root"
      )
    end

    def create_standby_resource(suffix)
      create_postgres_resource("postgres-standby-#{suffix}", ha_type: PostgresResource::HaType::SYNC)
    end

    it "does not set archival related configs if blob storage is not configured" do
      allow(Config).to receive(:postgres_service_project_id).and_return(nil)
      expect(postgres_server.configure_hash[:configs]).not_to include(:archive_mode, :archive_timeout, :archive_command, :synchronous_standby_names, :primary_conninfo, :recovery_target_time, :restore_command)
    end

    it "sets configs that are specific to primary" do
      expect(postgres_server.configure_hash[:configs]).to include(:archive_mode, :archive_timeout, :archive_command)
    end

    it "sets archive_command for walg client according to resource.use_old_walg_command_set?" do
      expect(resource).to receive(:use_old_walg_command_set?).and_return(true)
      expect(postgres_server.configure_hash[:configs]).to include(archive_command: "'/usr/bin/wal-g wal-push %p --config /etc/postgresql/wal-g.env'")
      expect(resource).to receive(:use_old_walg_command_set?).and_return(false).at_least(:once)
      expect(postgres_server.configure_hash[:configs]).to include(archive_command: "'/usr/bin/walg-daemon-client /tmp/wal-g wal-push %f'")
    end

    it "sets synchronous_standby_names for sync replication mode" do
      postgres_server
      resource.update(ha_type: PostgresResource::HaType::SYNC)

      described_class.create(
        timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "standby1").id,
        synchronization_status: "catching_up", timeline_access: "fetch", version: "16"
      )
      standby2 = described_class.create(
        timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "standby2").id,
        synchronization_status: "ready", timeline_access: "fetch", version: "16"
      )

      expect(postgres_server.configure_hash[:configs]).to include(synchronous_standby_names: "'ANY 1 (#{standby2.ubid})'")
    end

    it "sets synchronous_standby_names as empty if there is no caught up standby" do
      resource.update(ha_type: PostgresResource::HaType::SYNC)

      described_class.create(
        timeline:, resource: create_standby_resource("1"), vm_id: create_hosted_vm(project, private_subnet, "standby1").id, representative_at: Time.now,
        synchronization_status: "catching_up", timeline_access: "fetch", version: "16"
      )
      described_class.create(
        timeline:, resource: create_standby_resource("2"), vm_id: create_hosted_vm(project, private_subnet, "standby2").id, representative_at: Time.now,
        synchronization_status: "catching_up", timeline_access: "fetch", version: "16"
      )

      expect(postgres_server.configure_hash[:configs]).not_to include(:synchronous_standby_names)
    end

    it "sets configs that are specific to standby" do
      postgres_server.update(timeline_access: "fetch", representative_at: nil)
      primary_vm = create_hosted_vm(project, private_subnet, "primary")
      described_class.create(
        timeline:, resource:, vm_id: primary_vm.id, representative_at: Time.now,
        timeline_access: "push", version: "16"
      )
      expect(postgres_server.configure_hash[:configs]).to include(:primary_conninfo, :restore_command)
    end

    it "sets configs that are specific to restoring servers" do
      postgres_server.update(timeline_access: "fetch")
      resource.update(restore_target: Time.now)
      expect(postgres_server.configure_hash[:configs]).to include(:recovery_target_time, :restore_command)
    end

    it "puts pg_analytics to shared_preload_libraries for ParadeDB" do
      resource.update(flavor: PostgresResource::Flavor::PARADEDB)
      expect(postgres_server.configure_hash[:configs]).to include("shared_preload_libraries" => "'pg_cron,pg_stat_statements,pg_analytics,pg_search'")
    end

    it "puts lantern_extras to shared_preload_libraries for Lantern" do
      resource.update(flavor: PostgresResource::Flavor::LANTERN)
      expect(postgres_server.configure_hash[:configs]).to include("shared_preload_libraries" => "'pg_cron,pg_stat_statements,lantern_extras'")
    end

    it "puts extra logging options for AWS" do
      location.update(provider: "aws")
      postgres_server.timeline_access = "push"
      expect(postgres_server.configure_hash[:configs]).to include(:log_line_prefix, :log_connections, :log_disconnections)
    end
  end

  describe "#trigger_failover" do
    it "logs error when server is not primary" do
      postgres_server.update(representative_at: nil)
      expect(Clog).to receive(:emit).with("Cannot trigger failover on a non-representative server")
      expect(postgres_server.trigger_failover(mode: "planned")).to be false
    end

    it "logs error when no suitable standby found" do
      expect(Clog).to receive(:emit).with("No suitable standby found for failover")
      expect(postgres_server.trigger_failover(mode: "planned")).to be false
    end

    it "returns true only when failover is successfully triggered" do
      VmStorageVolume.create(vm:, disk_index: 0, boot: false, size_gib: 64)
      standby = create_failover_server(prefix: "standby", label: "wait")
      stub_current_lsn(standby.id => "0/0")
      expect(postgres_server.trigger_failover(mode: "planned")).to be true
      expect(standby.reload.planned_take_over_set?).to be true
    end
  end

  describe "#read_replica?" do
    it "returns true when resource has parent_id and no restore_target" do
      resource.update(parent_id: create_postgres_resource("parent").id)
      expect(postgres_server).to be_read_replica
    end

    it "returns false when resource has no parent_id" do
      expect(postgres_server).not_to be_read_replica
    end
  end

  describe "#failover_target" do
    before do
      postgres_server.update(representative_at: Time.now)
      VmStorageVolume.create(vm:, disk_index: 0, boot: false, size_gib: 64)
    end

    it "returns nil if there is no standby" do
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if there is no fresh standby" do
      create_failover_server(prefix: "standby", label: "wait", vm_size: "standard-4")
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns the standby with highest lsn in sync replication" do
      resource.update(ha_type: PostgresResource::HaType::SYNC)
      create_failover_server(prefix: "standby", label: "wait_catch_up")
      standby2 = create_failover_server(prefix: "standby", label: "wait")
      standby3 = create_failover_server(prefix: "standby", label: "wait")
      stub_current_lsn(standby2.id => "1/5", standby3.id => "1/10")
      expect(postgres_server.failover_target.ubid).to eq(standby3.ubid)
    end

    it "returns nil if last_known_lsn is unknown for async replication" do
      resource.update(ha_type: PostgresResource::HaType::ASYNC)
      PostgresLsnMonitor.create { it.postgres_server_id = postgres_server.id }
      standby = create_failover_server(prefix: "standby", label: "wait")
      stub_current_lsn(standby.id => "1/10")
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if lsn difference is too high for async replication" do
      resource.update(ha_type: PostgresResource::HaType::ASYNC)
      PostgresLsnMonitor.create { |m|
        m.postgres_server_id = postgres_server.id
        m.last_known_lsn = "2/0"
      }
      standby = create_failover_server(prefix: "standby", label: "wait")
      stub_current_lsn(standby.id => "1/10")
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns the standby with highest lsn if lsn difference is not high in async replication" do
      resource.update(ha_type: PostgresResource::HaType::ASYNC)
      PostgresLsnMonitor.create { |m|
        m.postgres_server_id = postgres_server.id
        m.last_known_lsn = "1/11"
      }
      create_failover_server(prefix: "standby", label: "wait_catch_up")
      standby2 = create_failover_server(prefix: "standby", label: "wait")
      standby3 = create_failover_server(prefix: "standby", label: "wait")
      stub_current_lsn(standby2.id => "1/5", standby3.id => "1/10")
      expect(postgres_server.failover_target.ubid).to eq(standby3.ubid)
    end

    context "when read replica" do
      before do
        resource.update(parent_id: create_postgres_resource("parent-resource").id)
      end

      it "returns nil if there is no replica to failover" do
        expect(postgres_server.failover_target).to be_nil
      end

      it "returns nil if there is no fresh read_replica" do
        create_failover_server(prefix: "replica", label: "wait", vm_size: "standard-4")
        expect(postgres_server.failover_target).to be_nil
      end

      it "returns the replica with highest lsn" do
        create_failover_server(prefix: "replica", label: "wait_catch_up")
        replica2 = create_failover_server(prefix: "replica", label: "wait")
        replica3 = create_failover_server(prefix: "replica", label: "wait")
        stub_current_lsn(replica2.id => "1/5", replica3.id => "1/10")
        expect(postgres_server.failover_target.ubid).to eq(replica3.ubid)
      end
    end
  end

  describe "storage_size_gib" do
    it "returns the storage size in GiB" do
      VmStorageVolume.create(vm:, disk_index: 0, boot: false, size_gib: 64)
      expect(postgres_server.storage_size_gib).to eq(64)
    end

    it "returns nil if there is no storage volume" do
      expect(postgres_server.storage_size_gib).to be_zero
    end
  end

  describe "lsn_caught_up" do
    before do
      parent_resource = create_postgres_resource("postgres-resource-parent")
      parent_vm = create_hosted_vm(project, private_subnet, "parent-vm")
      described_class.create(
        timeline:, resource: parent_resource, vm_id: parent_vm.id, representative_at: Time.now,
        synchronization_status: "ready", timeline_access: "push", version: "16"
      )
      resource.update(parent: parent_resource)
      postgres_server.update(timeline_access: "fetch")
    end

    it "returns true when LSNs match exactly" do
      expect(resource.parent.representative_server).to receive(:run_query).with("SELECT pg_current_wal_lsn()").and_return("F/F")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true when diff is just under 80MB (0x4FFFFFF bytes)" do
      # 80MB = 0x5000000 bytes, so 0x4FFFFFF is just under the threshold
      expect(resource.parent.representative_server).to receive(:run_query).with("SELECT pg_current_wal_lsn()").and_return("0/4FFFFFF")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("0/0")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true if read replica and the parent representative server is nil" do
      postgres_server.resource.representative_server.update(representative_at: nil)
      postgres_server.resource.update(restore_target: Time.now)
      expect(postgres_server.resource.representative_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true if read replica and the parent is nil" do
      postgres_server.resource.update(parent_id: PostgresResource.generate_ubid.to_uuid)
      expect(postgres_server.read_replica?).to be(true)
      expect(postgres_server.lsn_caught_up).to be(true)
    end

    it "returns false when diff is exactly 80MB (0x5000000 bytes)" do
      # 80MB = 0x5000000 bytes, threshold is < 80MB so exactly 80MB returns false
      expect(resource.parent.representative_server).to receive(:run_query).with("SELECT pg_current_wal_lsn()").and_return("0/5000000")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("0/0")
      expect(postgres_server.lsn_caught_up).to be_falsey
    end

    it "returns true if the diff is less than 80MB for not read replica and uses the main representative server" do
      resource.update(parent_id: nil, restore_target: Time.now)
      expect(postgres_server.resource.representative_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true when no representative server" do
      resource.update(parent_id: nil)
      postgres_server.update(representative_at: nil)
      expect(postgres_server.reload.lsn_caught_up).to be(true)
    end
  end

  it "initiates a new health monitor session" do
    forward = instance_double(Net::SSH::Service::Forward)
    expect(forward).to receive(:local_socket)
    session = Net::SSH::Connection::Session.allocate
    expect(session).to receive(:forward).and_return(forward)
    expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(session)
    postgres_server.init_health_monitor_session
  end

  it "initiates a new metrics export session" do
    session = Net::SSH::Connection::Session.allocate
    expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(session)
    postgres_server.init_metrics_export_session
  end

  it "checks pulse for restoring server (not primary, not standby) and does not trigger checkup when pulse recovers" do
    postgres_server.update(timeline_access: "fetch")
    result = postgres_server.check_pulse(session: check_pulse_session, previous_pulse: down_pulse)
    expect(result[:reading]).to eq("up")
    expect(postgres_server.reload.checkup_set?).to be false
  end

  it "increments checkup semaphore if pulse is down for a while and the resource is not upgrading" do
    postgres_server.update(timeline_access: "fetch", representative_at: nil)
    primary_vm = create_hosted_vm(project, private_subnet, "primary")
    described_class.create(
      timeline:, resource:, vm_id: primary_vm.id, representative_at: Time.now,
      timeline_access: "push", version: "16"
    )
    Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
    session = check_pulse_session(db_connection: instance_double(Sequel::Postgres::Database))
    expect(session[:db_connection]).to receive(:[]).and_raise(Sequel::DatabaseConnectionError)
    postgres_server.check_pulse(session:, previous_pulse: down_pulse)
    expect(postgres_server.reload.checkup_set?).to be true
  end

  it "uses pg_current_wal_lsn to track lsn for primaries" do
    Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
    session = check_pulse_session(db_connection: instance_double(Sequel::Postgres::Database))
    expect(session[:db_connection]).to receive(:[]).with("SELECT pg_current_wal_lsn() AS lsn").and_raise(Sequel::DatabaseConnectionError)
    postgres_server.check_pulse(session:, previous_pulse: down_pulse)
    expect(postgres_server.reload.checkup_set?).to be true
  end

  it "uses pg_last_wal_replay_lsn to track lsn for restoring servers" do
    postgres_server.update(timeline_access: "fetch")
    Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
    session = check_pulse_session(db_connection: instance_double(Sequel::Postgres::Database))
    expect(session[:db_connection]).to receive(:[]).with("SELECT pg_last_wal_replay_lsn() AS lsn").and_raise(Sequel::DatabaseConnectionError)
    postgres_server.check_pulse(session:, previous_pulse: down_pulse)
    expect(postgres_server.reload.checkup_set?).to be true
  end

  it "catches Sequel::Error if updating PostgresLsnMonitor fails" do
    expect(PostgresLsnMonitor).to receive(:new).and_wrap_original do |m, &block|
      lsn_monitor = m.call(&block)
      expect(lsn_monitor).to receive(:save_changes).and_raise(Sequel::Error)
      lsn_monitor
    end
    expect(postgres_server).to receive(:observe_archival_backlog)
    expect(Clog).to receive(:emit).with("Failed to update PostgresLsnMonitor").and_call_original
    postgres_server.check_pulse(session: {db_connection: DB}, previous_pulse: {})
  end

  it "runs query on vm" do
    expect(postgres_server.vm.sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: "SELECT 1").and_return("1\n")
    expect(postgres_server.run_query("SELECT 1")).to eq("1")
  end

  it "returns the right storage_device_paths for AWS" do
    vm # load before setting aws provider so test controls VmStorageVolume setup
    location.update(provider: "aws")
    VmStorageVolume.create(vm:, disk_index: 0, boot: true, size_gib: 64)
    VmStorageVolume.create(vm:, disk_index: 1, boot: false, size_gib: 1024)
    VmStorageVolume.create(vm:, disk_index: 2, boot: false, size_gib: 1024)
    expect(postgres_server.vm.sshable).to receive(:_cmd).with("lsblk -b -d -o NAME,SIZE | sort -n -k2 | tail -n2 |  awk '{print \"/dev/\"$1}'").and_return("/dev/nvme1n1\n/dev/nvme2n1\n")
    expect(postgres_server.storage_device_paths).to eq(["/dev/nvme1n1", "/dev/nvme2n1"])
  end

  it "returns the right storage_device_paths for Hetzner" do
    VmStorageVolume.create(vm:, disk_index: 0, boot: true, size_gib: 64)
    vsv = VmStorageVolume.create(vm:, disk_index: 1, boot: false, size_gib: 1024)
    expect(postgres_server.storage_device_paths).to eq([vsv.device_path])
  end

  describe "#taking_over?" do
    it "returns true if the strand label is 'taking_over'" do
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "taking_over")
      expect(postgres_server.taking_over?).to be true
    end

    it "returns false if the strand label is not 'taking_over'" do
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
      expect(postgres_server.taking_over?).to be false
    end
  end

  describe "#switch_to_new_timeline" do
    it "switches to new timeline with current parent" do
      old_timeline = postgres_server.timeline
      postgres_server.switch_to_new_timeline
      postgres_server.reload
      expect(postgres_server.timeline_id).not_to eq(old_timeline.id)
      expect(postgres_server.timeline_access).to eq("push")
      expect(postgres_server.timeline.parent_id).to eq(old_timeline.id)
    end

    it "switches to new timeline without current parent" do
      old_timeline = postgres_server.timeline
      postgres_server.switch_to_new_timeline(parent_id: nil)
      postgres_server.reload
      expect(postgres_server.timeline_id).not_to eq(old_timeline.id)
      expect(postgres_server.timeline_access).to eq("push")
      expect(postgres_server.timeline.parent_id).to be_nil
    end
  end

  describe "#refresh_walg_credentials" do
    it "does nothing if timeline has no blob storage" do
      expect(postgres_server.timeline.blob_storage).to be_nil
      expect(vm.sshable).not_to receive(:_cmd)
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end

    it "refreshes walg credentials if timeline has blob storage not on aws" do
      allow(Config).to receive_messages(minio_service_project_id: project_service.id, minio_host_name: "minio.test")
      DnsZone.create(project_id: project_service.id, name: "minio.test")
      MinioCluster.create(project_id: project_service.id, location:, name: "walg-minio", admin_user: "root", admin_password: "root", root_cert_1: "root_certs")
      expected_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{timeline.ubid}
AWS_ENDPOINT=https://walg-minio.minio.test:9000

AWS_REGION=us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/16/data
      WALG_CONF
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: expected_config)
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "root_certs")
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end

    it "refreshes walg credentials if timeline has blob storage on aws" do
      location.update(provider: "aws", name: "us-east-1")
      expected_config = <<-WALG_CONF
WALG_S3_PREFIX=s3://#{timeline.ubid}
AWS_ENDPOINT=https://s3.us-east-1.amazonaws.com

AWS_REGION=us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
PGDATA=/dat/16/data
      WALG_CONF
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: expected_config)
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end
  end

  describe "#observe_archival_backlog" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    before do
      allow(postgres_server).to receive(:archival_backlog_threshold).and_return(10)
    end

    it "checks archival backlog and does nothing if it is within limits" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_return("5\n")
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect(Page).to receive(:from_tag_parts).with("PGArchivalBacklogHigh", postgres_server.id).and_return(nil)

      postgres_server.observe_archival_backlog(session:)
    end

    it "checks archival backlog and creates a page if it is outside of limits" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_return("15\n")
      expect(Prog::PageNexus).to receive(:assemble).with(
        "#{postgres_server.ubid} archival backlog high",
        ["PGArchivalBacklogHigh", postgres_server.id],
        postgres_server.ubid,
        severity: "warning",
        extra_data: {archival_backlog: 15}
      )

      postgres_server.observe_archival_backlog(session:)
    end

    it "checks archival backlog and resolves a page if it is back within limits" do
      existing_page = instance_double(Page)
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_return("3\n")
      expect(Page).to receive(:from_tag_parts).with("PGArchivalBacklogHigh", postgres_server.id).and_return(existing_page)
      expect(existing_page).to receive(:incr_resolve)

      postgres_server.observe_archival_backlog(session:)
    end
  end

  describe "#archival_backlog_threshold" do
    it "returns 1000 if the storage size is large" do
      allow(postgres_server).to receive(:storage_size_gib).and_return(1024)
      expect(postgres_server.archival_backlog_threshold).to eq(1000)
    end

    it "returns smaller threshold for smaller storage sizes" do
      allow(postgres_server).to receive(:storage_size_gib).and_return(100)
      expect(postgres_server.archival_backlog_threshold).to eq(320)
    end
  end

  describe "#metrics_config" do
    it "includes additional_labels from resource tags" do
      postgres_server.resource.update(tags: {"env" => "prod", "team" => "devops"})
      config = postgres_server.metrics_config
      expect(config[:additional_labels]).to eq({"pg_tags_label_env" => "prod", "pg_tags_label_team" => "devops"})
    end
  end

  if Config.unfrozen_test?
    describe "#attach_s3_policy_if_needed" do
      before do
        allow(Config).to receive(:aws_postgres_iam_access).and_return(true)
        AwsInstance.create_with_id(vm, iam_role: "role")
      end

      it "calls attach_role_policy when needs s3 policy attachment" do
        location.update(provider: "aws")
        iam_client = Aws::IAM::Client.new(stub_responses: true)
        LocationCredential.create(location:, assume_role: "role")
        expect(postgres_server.timeline.location.location_credential).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
        expect(postgres_server.timeline.location.location_credential).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:attach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.aws_s3_policy_arn)
        postgres_server.attach_s3_policy_if_needed
      end

      it "does not call attach_role_policy when needs s3 policy attachment" do
        expect(postgres_server).not_to receive(:vm)
        postgres_server.attach_s3_policy_if_needed
      end
    end
  end
end
