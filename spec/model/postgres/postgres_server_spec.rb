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

  def create_postgres_resource(name, location: self.location, **)
    PostgresResource.create(
      name:, project:, location:,
      ha_type: PostgresResource::HaType::NONE,
      target_version: "16", target_vm_size: "standard-2", target_storage_size_gib: 64,
      superuser_password: "super",
      **
    )
  end

  def create_aws_location(name: "test-aws-location")
    Location.create(
      name:, project:,
      display_name: name, ui_name: name,
      provider: "aws", visible: true
    )
  end

  def create_postgres_server(target_resource: resource, target_timeline: timeline, target_vm: nil,
    timeline_access: "push", representative: true, version: "16", synchronization_status: "ready")
    @server_vm_counter = (@server_vm_counter || 0) + 1
    server_vm = target_vm || create_hosted_vm(project, private_subnet, "server-vm-#{@server_vm_counter}")
    described_class.create(
      timeline: target_timeline, resource: target_resource, vm_id: server_vm.id,
      representative_at: representative ? Time.now : nil,
      synchronization_status:, timeline_access:, version:
    )
  end

  def add_data_volume(target_vm = vm, size_gib: 64)
    VmStorageVolume.create(vm: target_vm, disk_index: 0, boot: false, size_gib:)
  end

  def create_failover_server(prefix:, label:, vm_size: "standard-2", target_resource: resource)
    @failover_counter = (@failover_counter || 0) + 1
    server_vm = create_hosted_vm(project, private_subnet, "#{prefix}-#{@failover_counter}", size: vm_size)
    add_data_volume(server_vm)
    server = described_class.create(
      timeline:, resource: target_resource, vm_id: server_vm.id,
      synchronization_status: "ready", timeline_access: "fetch", version: "16"
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label:)
    server
  end

  def stub_current_lsn(lsn_by_id)
    resource.servers.each do |s|
      next unless (lsn = lsn_by_id[s.id])
      allow(s).to receive(:_run_query)
        .with(satisfy { |sql| sql.include?("_lsn") })
        .and_return(lsn)
    end
  end

  def down_pulse
    {reading: "down", reading_rpt: 5, reading_chg: Time.now - 30}
  end

  def check_pulse_session(db_connection: DB)
    {ssh_session: Net::SSH::Connection::Session.allocate, db_connection:}
  end

  describe "#configure" do
    it "does not set archival related configs if blob storage is not configured" do
      expect(Config).to receive(:postgres_service_project_id).and_return(nil)
      expect(postgres_server.configure_hash[:configs]).not_to include(:archive_mode, :archive_timeout, :archive_command, :synchronous_standby_names, :primary_conninfo, :recovery_target_time, :restore_command)
    end
  end

  describe "#configure", "with blob storage" do
    before do
      MinioCluster.create(
        project_id: Config.postgres_service_project_id, location:, name: "pgminio", admin_user: "root", admin_password: "root"
      )
    end

    it "sets configs that are specific to primary" do
      expect(postgres_server.configure_hash[:configs]).to include(:archive_mode, :archive_timeout, :archive_command)
    end

    it "sets synchronized_standby_slots on Postgres 17" do
      postgres_server.update(version: "17")
      expect(postgres_server.configure_hash[:configs]).to include(:synchronized_standby_slots)
    end

    it "sets archive_command for walg client according to resource.use_old_walg_command_set?" do
      Strand.create_with_id(resource, prog: "Postgres::PostgresResourceNexus", label: "wait")
      resource.incr_use_old_walg_command
      expect(postgres_server.reload.configure_hash[:configs]).to include(archive_command: "'/usr/bin/wal-g wal-push %p --config /etc/postgresql/wal-g.env'")
      Semaphore.where(strand_id: resource.id, name: "use_old_walg_command").destroy
      expect(postgres_server.reload.configure_hash[:configs]).to include(archive_command: "'/usr/bin/walg-daemon-client /tmp/wal-g wal-push %f'")
    end

    it "sets synchronous_standby_names for sync replication mode" do
      sync_resource = create_postgres_resource("sync-resource", ha_type: PostgresResource::HaType::SYNC)
      primary = create_postgres_server(target_resource: sync_resource)

      create_postgres_server(target_resource: sync_resource, timeline_access: "fetch", representative: false, synchronization_status: "catching_up")
      standby2 = create_postgres_server(target_resource: sync_resource, timeline_access: "fetch", representative: false)

      expect(primary.configure_hash[:configs]).to include(synchronous_standby_names: "'ANY 1 (#{standby2.ubid})'")
    end

    it "sets synchronous_standby_names as empty if there is no caught up standby" do
      sync_resource = create_postgres_resource("sync-resource", ha_type: PostgresResource::HaType::SYNC)
      primary = create_postgres_server(target_resource: sync_resource)

      # Standbys belong to different resources (not the primary's resource)
      standby_resource1 = create_postgres_resource("standby-resource-1", ha_type: PostgresResource::HaType::SYNC)
      standby_resource2 = create_postgres_resource("standby-resource-2", ha_type: PostgresResource::HaType::SYNC)
      create_postgres_server(target_resource: standby_resource1, timeline_access: "fetch", synchronization_status: "catching_up")
      create_postgres_server(target_resource: standby_resource2, timeline_access: "fetch", synchronization_status: "catching_up")

      expect(primary.configure_hash[:configs]).not_to include(:synchronous_standby_names)
    end

    it "sets configs that are specific to standby" do
      standby = create_postgres_server(timeline_access: "fetch", representative: false)
      create_postgres_server(target_resource: resource) # primary
      expect(standby.configure_hash[:configs]).to include(:primary_conninfo, :restore_command)
    end

    it "sets configs that are specific to restoring servers" do
      restoring_resource = create_postgres_resource("restoring", restore_target: Time.now)
      restoring_server = create_postgres_server(target_resource: restoring_resource, timeline_access: "fetch")
      expect(restoring_server.configure_hash[:configs]).to include(:recovery_target_time, :restore_command)
    end

    it "sets primary_slot_name to ubid on standby when physical_slot_ready" do
      postgres_server.timeline_access = "fetch"
      expect(postgres_server.configure_hash.dig(:configs, :primary_slot_name)).to be_nil
      postgres_server.physical_slot_ready = true
      expect(postgres_server.configure_hash.dig(:configs, :primary_slot_name)).to eq("'#{postgres_server.ubid}'")
    end

    it "puts pg_analytics to shared_preload_libraries for ParadeDB" do
      paradedb_resource = create_postgres_resource("paradedb-resource", flavor: PostgresResource::Flavor::PARADEDB)
      paradedb_server = create_postgres_server(target_resource: paradedb_resource)
      expect(paradedb_server.configure_hash[:configs]).to include("shared_preload_libraries" => "'pg_cron,pg_stat_statements,pg_analytics,pg_search'")
    end

    it "puts lantern_extras to shared_preload_libraries for Lantern" do
      lantern_resource = create_postgres_resource("lantern-resource", flavor: PostgresResource::Flavor::LANTERN)
      lantern_server = create_postgres_server(target_resource: lantern_resource)
      expect(lantern_server.configure_hash[:configs]).to include("shared_preload_libraries" => "'pg_cron,pg_stat_statements,lantern_extras'")
    end

    it "puts extra logging options for AWS" do
      location.update(provider: "aws")
      postgres_server.timeline_access = "push"
      expect(postgres_server.configure_hash[:configs]).to include(:log_line_prefix, :log_connections, :log_disconnections)
    end

    it "sets allow_alter_system to off for version >= 17" do
      postgres_server.update(version: "17")
      expect(postgres_server.configure_hash[:configs]).to include("allow_alter_system" => "off")
    end
  end

  describe "#trigger_failover" do
    it "logs error when server is not primary" do
      non_primary = create_postgres_server(representative: false)
      expect(Clog).to receive(:emit).with("Cannot trigger failover on a non-representative server", {ubid: non_primary.ubid})
      expect(non_primary.trigger_failover(mode: "planned")).to be false
    end

    it "logs error when no suitable standby found" do
      expect(Clog).to receive(:emit).with("No suitable standby found for failover", {ubid: postgres_server.ubid})
      expect(postgres_server.trigger_failover(mode: "planned")).to be false
    end

    it "returns true only when failover is successfully triggered" do
      add_data_volume
      standby = create_failover_server(prefix: "standby", label: "wait")
      stub_current_lsn(standby.id => "0/0")
      expect(postgres_server.trigger_failover(mode: "planned")).to be true
      expect(standby.reload.planned_take_over_set?).to be true
    end
  end

  describe "#read_replica?" do
    it "returns true when resource has parent_id and no restore_target" do
      parent = create_postgres_resource("parent")
      replica_resource = create_postgres_resource("replica", parent_id: parent.id)
      replica_server = create_postgres_server(target_resource: replica_resource)
      expect(replica_server).to be_read_replica
    end

    it "returns false when resource has no parent_id" do
      expect(postgres_server).not_to be_read_replica
    end
  end

  describe "#failover_target" do
    before do
      add_data_volume
    end

    it "returns nil if there is no standby" do
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if there is no fresh standby" do
      create_failover_server(prefix: "standby", label: "wait", vm_size: "standard-4")
      expect(postgres_server.failover_target).to be_nil
    end

    context "with sync replication" do
      let(:resource) { create_postgres_resource("sync-resource", ha_type: PostgresResource::HaType::SYNC) }

      it "returns the standby with highest lsn" do
        create_failover_server(prefix: "standby", label: "wait_catch_up")
        standby2 = create_failover_server(prefix: "standby", label: "wait")
        standby3 = create_failover_server(prefix: "standby", label: "wait")
        stub_current_lsn(standby2.id => "1/5", standby3.id => "1/10")
        expect(postgres_server.failover_target.ubid).to eq(standby3.ubid)
      end
    end

    context "with async replication" do
      let(:resource) { create_postgres_resource("async-resource", ha_type: PostgresResource::HaType::ASYNC) }

      it "returns nil if last_known_lsn is unknown" do
        PostgresLsnMonitor.create { it.postgres_server_id = postgres_server.id }
        standby = create_failover_server(prefix: "standby", label: "wait")
        stub_current_lsn(standby.id => "1/10")
        expect(postgres_server.failover_target).to be_nil
      end

      it "returns nil if no lsn_monitor" do
        standby = create_failover_server(prefix: "standby", label: "wait")
        stub_current_lsn(standby.id => "1/10")
        expect(postgres_server.failover_target).to be_nil
      end

      it "returns nil if lsn difference is too high" do
        PostgresLsnMonitor.create { |m|
          m.postgres_server_id = postgres_server.id
          m.last_known_lsn = "2/0"
        }
        standby = create_failover_server(prefix: "standby", label: "wait")
        stub_current_lsn(standby.id => "1/10")
        expect(postgres_server.failover_target).to be_nil
      end

      it "returns the standby with highest lsn if lsn difference is not high" do
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
    end

    context "when read replica" do
      let(:parent_resource) { create_postgres_resource("parent-resource") }
      let(:resource) { create_postgres_resource("replica-resource", parent_id: parent_resource.id) }

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
      add_data_volume
      expect(postgres_server.storage_size_gib).to eq(64)
    end

    it "returns nil if there is no storage volume" do
      expect(postgres_server.storage_size_gib).to be_zero
    end
  end

  describe "lsn_caught_up" do
    it "returns true if read replica and the parent is nil" do
      # Create a replica with a non-existent parent (simulates orphaned replica)
      replica_resource = create_postgres_resource("replica", parent_id: PostgresResource.generate_uuid)
      replica_server = create_postgres_server(target_resource: replica_resource)
      expect(replica_server.read_replica?).to be(true)
      expect(replica_server.lsn_caught_up).to be(true)
    end

    it "returns true when no representative server" do
      non_rep_server = create_postgres_server(representative: false)
      expect(non_rep_server).to receive(:read_replica?).and_return(false)
      expect(non_rep_server.lsn_caught_up).to be(true)
    end
  end

  describe "lsn_caught_up", "with parent resource" do
    subject(:postgres_server) {
      described_class.create(
        timeline:, resource:, vm_id: vm.id, representative_at: Time.now,
        synchronization_status: "ready", timeline_access: "fetch", version: "16"
      )
    }

    let(:parent_resource) { create_postgres_resource("postgres-resource-parent") }
    let(:resource) { create_postgres_resource("replica-resource", parent_id: parent_resource.id) }

    before do
      parent_vm = create_hosted_vm(project, private_subnet, "parent-vm")
      described_class.create(
        timeline:, resource: parent_resource, vm_id: parent_vm.id, representative_at: Time.now,
        synchronization_status: "ready", timeline_access: "push", version: "16"
      )
      allow(resource.parent.representative_server).to receive(:current_lsn).and_return("F/F")
    end

    it "returns true if the diff is less than 80MB" do
      expect(postgres_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true if read replica and the parent representative server is nil" do
      postgres_server.resource.representative_server.update(representative_at: nil)
      postgres_server.resource.update(restore_target: Time.now)
      expect(postgres_server.resource.representative_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns false if the diff is more than 80MB" do
      expect(postgres_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("1/00000000")
      expect(postgres_server.lsn_caught_up).to be_falsey
    end

    it "returns true if the diff is less than 80MB for not read replica and uses the main representative server" do
      expect(postgres_server).to receive(:read_replica?).and_return(false)
      resource.update(restore_target: Time.now)
      expect(postgres_server.resource.representative_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
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
    restoring_server = create_postgres_server(timeline_access: "fetch")
    result = restoring_server.check_pulse(session: check_pulse_session, previous_pulse: down_pulse)
    expect(result[:reading]).to eq("up")
    expect(restoring_server.reload.checkup_set?).to be false
  end

  it "increments checkup semaphore if pulse is down for a while and the resource is not upgrading" do
    standby = create_postgres_server(timeline_access: "fetch", representative: false)
    create_postgres_server(target_resource: resource) # primary
    Strand.create_with_id(standby, prog: "Postgres::PostgresServerNexus", label: "wait")
    session = check_pulse_session(db_connection: instance_double(Sequel::Postgres::Database))
    expect(session[:db_connection]).to receive(:get).and_raise(Sequel::DatabaseConnectionError)
    standby.check_pulse(session:, previous_pulse: down_pulse)
    expect(standby.reload.checkup_set?).to be true
  end

  it "uses pg_current_wal_lsn to track lsn for primaries" do
    Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
    session = check_pulse_session(db_connection: instance_double(Sequel::Postgres::Database))
    expect(session[:db_connection]).to receive(:get).with(Sequel.function("pg_current_wal_lsn").as(:lsn)).and_raise(Sequel::DatabaseConnectionError)
    postgres_server.check_pulse(session:, previous_pulse: down_pulse)
    expect(postgres_server.reload.checkup_set?).to be true
  end

  it "uses pg_last_wal_replay_lsn to track lsn for restoring servers" do
    restoring_server = create_postgres_server(timeline_access: "fetch")
    Strand.create_with_id(restoring_server, prog: "Postgres::PostgresServerNexus", label: "wait")
    session = check_pulse_session(db_connection: instance_double(Sequel::Postgres::Database))
    expect(session[:db_connection]).to receive(:get).with(Sequel.function("pg_last_wal_replay_lsn").as(:lsn)).and_raise(Sequel::DatabaseConnectionError)
    restoring_server.check_pulse(session:, previous_pulse: down_pulse)
    expect(restoring_server.reload.checkup_set?).to be true
  end

  it "catches Sequel::Error if updating PostgresLsnMonitor fails" do
    expect(PostgresLsnMonitor).to receive(:new).and_wrap_original do |m, &block|
      lsn_monitor = m.call(&block)
      expect(lsn_monitor).to receive(:save_changes).and_raise(Sequel::Error)
      lsn_monitor
    end
    expect(Clog).to receive(:emit).with("Failed to update PostgresLsnMonitor", instance_of(Hash)).and_call_original
    postgres_server.check_pulse(session: {db_connection: DB}, previous_pulse: {})
  end

  it "runs query on vm" do
    expect(postgres_server.vm.sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: "SELECT 1").and_return("1\n")
    expect(postgres_server.run_query("SELECT 1")).to eq("1")
  end

  it "raises PotentialInsecurity when query is an unfrozen string" do
    unfrozen_query = +"SELECT 1"
    expect { postgres_server.run_query(unfrozen_query) }.to raise_error(NetSsh::PotentialInsecurity, /Interpolated string passed to PostgresServer#run_query/)
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

    it "configure new timeline on AWS" do
      location.update(provider: "aws", name: "us-east-1")
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
      old_timeline_id = postgres_server.timeline_id
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl stop wal-g")
      expect(postgres_server).to receive(:refresh_walg_credentials)

      postgres_server.switch_to_new_timeline

      postgres_server.reload
      expect(postgres_server.timeline_id).not_to eq(old_timeline_id)
      expect(postgres_server.timeline_access).to eq("push")
      expect(postgres_server.timeline.parent_id).to eq(old_timeline_id)
      expect(postgres_server.configure_s3_new_timeline_set?).to be true
    end
  end

  describe "#refresh_walg_credentials" do
    it "does nothing if timeline has no blob storage" do
      expect(postgres_server.timeline.blob_storage).to be_nil
      expect(vm.sshable).not_to receive(:_cmd)
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end

    it "refreshes walg credentials if timeline has blob storage not on aws" do
      expect(Config).to receive(:minio_service_project_id).and_return(project_service.id).at_least(:once)
      expect(Config).to receive(:minio_host_name).and_return("minio.test").at_least(:once)
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
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl restart wal-g")
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
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl restart wal-g")
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end

    it "does not restart wal-g if use_old_walg_command_set is true" do
      expect(Config).to receive(:minio_service_project_id).and_return(project_service.id).at_least(:once)
      expect(Config).to receive(:minio_host_name).and_return("minio.test").at_least(:once)
      DnsZone.create(project_id: project_service.id, name: "minio.test")
      MinioCluster.create(project_id: project_service.id, location:, name: "walg-minio", admin_user: "root", admin_password: "root", root_cert_1: "root_certs")
      Strand.create_with_id(resource, prog: "Postgres::PostgresResourceNexus", label: "wait")
      resource.incr_use_old_walg_command

      expected_config = timeline.generate_walg_config(postgres_server.version)
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: expected_config)
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "root_certs")
      expect(postgres_server.vm.sshable).not_to receive(:_cmd).with("sudo systemctl restart wal-g")

      postgres_server.refresh_walg_credentials
    end
  end

  describe "#export_metrics" do
    let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }
    let(:tsdb_client) { instance_double(VictoriaMetrics::Client) }

    it "calls observe_archival_backlog at export counts where count % 12 == 1" do
      session[:export_count] = 12
      expect(postgres_server).to receive(:scrape_endpoints).and_return([])
      expect(postgres_server).to receive(:observe_archival_backlog).with(session)
      expect(postgres_server).not_to receive(:observe_metrics_backlog)

      postgres_server.export_metrics(session:, tsdb_client:)
    end

    it "calls observe_metrics_backlog at export counts where count % 12 == 7" do
      session[:export_count] = 6
      allow(postgres_server).to receive(:scrape_endpoints).and_return([])
      expect(postgres_server).not_to receive(:observe_archival_backlog)
      expect(postgres_server).to receive(:observe_metrics_backlog).with(session)

      postgres_server.export_metrics(session:, tsdb_client:)
    end

    it "does not call observe_archival_backlog or observe_metrics_backlog on every export" do
      session[:export_count] = 2
      expect(postgres_server).to receive(:scrape_endpoints).and_return([])
      expect(postgres_server).not_to receive(:observe_archival_backlog).with(session)
      expect(postgres_server).not_to receive(:observe_metrics_backlog).with(session)

      postgres_server.export_metrics(session:, tsdb_client:)
    end

    it "increments export_count in session" do
      allow(postgres_server).to receive(:observe_archival_backlog).with(session)
      allow(postgres_server).to receive(:observe_metrics_backlog).with(session)
      allow(postgres_server).to receive(:scrape_endpoints).and_return([])

      expect(session[:export_count]).to be_nil
      postgres_server.export_metrics(session:, tsdb_client:)
      expect(session[:export_count]).to eq(1)

      postgres_server.export_metrics(session:, tsdb_client:)
      expect(session[:export_count]).to eq(2)
    end
  end

  describe "#observe_archival_backlog" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    before do
      # Use 32 GiB storage which gives threshold of 10 (32*1024/1600*5 = 102, then capped)
      # For smaller threshold, use smaller storage: 5 GiB => 5*1024/1600*5 = 16, rounded to 16
      add_data_volume(vm, size_gib: 5)
    end

    it "checks archival backlog and does nothing if it is within limits" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_return("5\n")

      expect { postgres_server.observe_archival_backlog(session) }
        .not_to change(Page, :count)
    end

    it "checks archival backlog and creates a page if it is outside of limits" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_return("20\n")

      expect { postgres_server.observe_archival_backlog(session) }
        .to change(Page, :count).by(1)

      page = Page.first(tag: Page.generate_tag(["PGArchivalBacklogHigh", postgres_server.id]))
      expect(page.summary).to eq("#{postgres_server.ubid} archival backlog high")
      expect(page.severity).to eq("warning")
      expect(page.details["archival_backlog"]).to eq(20)
    end

    it "checks archival backlog and resolves a page if it is back within limits" do
      tag = Page.generate_tag(["PGArchivalBacklogHigh", postgres_server.id])
      existing_page = Page.create(summary: "test page", tag:, severity: "warning")
      Strand.create_with_id(existing_page, prog: "PageNexus", label: "wait")

      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_return("3\n")

      postgres_server.observe_archival_backlog(session)
      expect(existing_page.reload.resolve_set?).to be true
    end
  end

  describe "#observe_archival_backlog", "with SSH error" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    it "logs errors when checking archival backlog fails" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_raise(Net::SSH::Exception.new("SSH error"))
      expect(Clog).to receive(:emit).with("Failed to observe archival backlog", instance_of(Hash)).and_call_original

      postgres_server.observe_archival_backlog(session)
    end
  end

  describe "#archival_backlog_threshold" do
    it "returns 1000 if the storage size is large" do
      expect(postgres_server).to receive(:storage_size_gib).and_return(1024)
      expect(postgres_server.archival_backlog_threshold).to eq(1000)
    end

    it "returns smaller threshold for smaller storage sizes" do
      expect(postgres_server).to receive(:storage_size_gib).and_return(100)
      expect(postgres_server.archival_backlog_threshold).to eq(320)
    end
  end

  describe "#observe_metrics_backlog" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    before do
      allow(postgres_server).to receive(:metrics_config).and_return({
        metrics_dir: "/home/ubi/postgres/metrics",
        interval: "15s"
      })
    end

    it "checks metrics backlog and does nothing if it is within limits" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "find /home/ubi/postgres/metrics/done -name '*.txt' | wc -l"
      ).and_return("10\n")
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect(Page).to receive(:from_tag_parts).with("PGMetricsBacklogHigh", postgres_server.id).and_return(nil)

      postgres_server.observe_metrics_backlog(session)
    end

    it "checks metrics backlog and creates a page if it exceeds threshold" do
      # 30 files * 15 seconds = 450 > 300 threshold
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "find /home/ubi/postgres/metrics/done -name '*.txt' | wc -l"
      ).and_return("30\n")
      expect(Prog::PageNexus).to receive(:assemble).with(
        "#{postgres_server.ubid} metrics backlog high",
        ["PGMetricsBacklogHigh", postgres_server.id],
        postgres_server.ubid,
        severity: "warning",
        extra_data: {metrics_backlog: 30}
      )

      postgres_server.observe_metrics_backlog(session)
    end

    it "checks metrics backlog and resolves a page if it is back within limits" do
      existing_page = instance_double(Page)
      # 10 files * 15 seconds = 150 < 300 threshold
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "find /home/ubi/postgres/metrics/done -name '*.txt' | wc -l"
      ).and_return("10\n")
      expect(Page).to receive(:from_tag_parts).with("PGMetricsBacklogHigh", postgres_server.id).and_return(existing_page)
      expect(existing_page).to receive(:incr_resolve)

      postgres_server.observe_metrics_backlog(session)
    end

    it "logs errors when checking metrics backlog fails" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "find /home/ubi/postgres/metrics/done -name '*.txt' | wc -l"
      ).and_raise(Net::SSH::Exception.new("SSH error"))
      expect(Clog).to receive(:emit).with("Failed to observe metrics backlog", instance_of(Hash)).and_call_original

      postgres_server.observe_metrics_backlog(session)
    end
  end

  describe "#metrics_config" do
    it "includes additional_labels from resource tags" do
      tagged_resource = create_postgres_resource("tagged-resource", tags: {"env" => "prod", "team" => "devops"})
      tagged_server = create_postgres_server(target_resource: tagged_resource)
      config = tagged_server.metrics_config
      expect(config[:additional_labels]).to eq({"pg_tags_label_env" => "prod", "pg_tags_label_team" => "devops"})
    end
  end

  if Config.unfrozen_test?
    describe "#attach_s3_policy_if_needed" do
      context "with AWS location" do
        let(:location) { create_aws_location(name: "us-west-2") }
        let(:iam_client) { Aws::IAM::Client.new(stub_responses: true) }

        before do
          AwsInstance.create_with_id(vm, iam_role: "role")
          LocationCredential.create(location:, assume_role: "role")
        end

        it "calls attach_role_policy when Config.aws_postgres_iam_access is true" do
          expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
          expect(postgres_server.timeline.location.location_credential).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
          expect(postgres_server.timeline.location.location_credential).to receive(:iam_client).and_return(iam_client)
          expect(iam_client).to receive(:attach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.aws_s3_policy_arn)
          postgres_server.attach_s3_policy_if_needed
        end

        context "with parent timeline" do
          let(:parent_timeline) { PostgresTimeline.create(location:) }
          let(:timeline) { PostgresTimeline.create(location:, parent: parent_timeline) }

          it "detaches parent timeline when Config.aws_postgres_iam_access is true" do
            expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
            expect(postgres_server.timeline.location.location_credential).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
            expect(postgres_server.timeline.location.location_credential).to receive(:iam_client).and_return(iam_client)
            expect(iam_client).to receive(:attach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.aws_s3_policy_arn)
            expect(iam_client).to receive(:detach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.parent.aws_s3_policy_arn)
            postgres_server.attach_s3_policy_if_needed
          end
        end

        it "does not attach policy when Config.aws_postgres_iam_access is not set" do
          expect(postgres_server.vm.aws_instance).not_to receive(:iam_role)
          postgres_server.attach_s3_policy_if_needed
        end
      end

      it "does not call attach_role_policy for non-AWS location" do
        LocationCredential.create(location:, assume_role: "role")
        expect(postgres_server.timeline.location.location_credential).not_to receive(:aws_iam_account_id)
        postgres_server.attach_s3_policy_if_needed
      end
    end
  end
end
