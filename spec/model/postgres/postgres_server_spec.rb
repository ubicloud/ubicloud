# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresServer do
  subject(:postgres_server) {
    described_class.create(
      timeline:, resource:, vm_id: vm.id, is_representative: true,
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

  it "#aws? delegates through vm location" do
    expect(postgres_server.aws?).to be false
  end

  describe "#configure" do
    before do
      resource.update(flavor: PostgresResource::Flavor::STANDARD, cert_auth_users: [])
      MinioCluster.create(
        project_id: Config.postgres_service_project_id, location:, name: "pgminio", admin_user: "root", admin_password: "root"
      )
    end

    def create_standby_resource(suffix)
      PostgresResource.create(
        name: "postgres-standby-#{suffix}",
        project:,
        location:,
        ha_type: PostgresResource::HaType::SYNC,
        user_config: {},
        pgbouncer_user_config: {},
        target_version: "16",
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        superuser_password: "super"
      )
    end

    it "does not set archival related configs if blob storage is not configured" do
      allow(Config).to receive(:postgres_service_project_id).and_return(nil)
      expect(postgres_server.configure_hash[:configs]).not_to include(:archive_mode, :archive_timeout, :archive_command, :synchronous_standby_names, :primary_conninfo, :recovery_target_time, :restore_command)
    end

    it "sets configs that are specific to primary" do
      expect(postgres_server.configure_hash[:configs]).to include(:archive_mode, :archive_timeout, :archive_command)
    end

    it "sets synchronized_standby_slots on Postgres 17" do
      postgres_server.update(version: "17")
      expect(postgres_server.configure_hash[:configs]).to include(:synchronized_standby_slots)
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
        timeline:, resource: create_standby_resource("1"), vm_id: create_hosted_vm(project, private_subnet, "standby1").id, is_representative: true,
        synchronization_status: "catching_up", timeline_access: "fetch", version: "16"
      )
      described_class.create(
        timeline:, resource: create_standby_resource("2"), vm_id: create_hosted_vm(project, private_subnet, "standby2").id, is_representative: true,
        synchronization_status: "catching_up", timeline_access: "fetch", version: "16"
      )

      expect(postgres_server.configure_hash[:configs]).not_to include(:synchronous_standby_names)
    end

    it "sets configs that are specific to standby" do
      postgres_server.timeline_access = "fetch"
      expect(postgres_server).to receive(:doing_pitr?).and_return(false).at_least(:once)
      expect(resource).to receive(:replication_connection_string)
      expect(postgres_server.configure_hash[:configs]).to include(:primary_conninfo, :restore_command)
    end

    it "sets configs that are specific to restoring servers" do
      postgres_server.update(timeline_access: "fetch")
      expect(resource).to receive(:restore_target)
      expect(postgres_server.configure_hash[:configs]).to include(:recovery_target_time, :restore_command)
    end

    it "sets primary_slot_name to ubid on standby when physical_slot_ready" do
      postgres_server.timeline_access = "fetch"
      expect(postgres_server.configure_hash.dig(:configs, :primary_slot_name)).to be_nil
      postgres_server.physical_slot_ready = true
      expect(postgres_server.configure_hash.dig(:configs, :primary_slot_name)).to eq("'#{postgres_server.ubid}'")
    end

    it "puts pg_analytics to shared_preload_libraries for ParadeDB" do
      postgres_server.timeline_access = "push"
      expect(resource).to receive(:flavor).and_return(PostgresResource::Flavor::PARADEDB)
      expect(postgres_server.configure_hash[:configs]).to include("shared_preload_libraries" => "'pg_cron,pg_stat_statements,pg_analytics,pg_search'")
    end

    it "puts lantern_extras to shared_preload_libraries for Lantern" do
      postgres_server.timeline_access = "push"
      expect(resource).to receive(:flavor).and_return(PostgresResource::Flavor::LANTERN).at_least(:once)
      expect(postgres_server.configure_hash[:configs]).to include("shared_preload_libraries" => "'pg_cron,pg_stat_statements,lantern_extras'")
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
      expect(postgres_server).to receive(:is_representative).and_return(false)
      expect(Clog).to receive(:emit).with("Cannot trigger failover on a non-representative server", instance_of(Hash))
      expect(postgres_server.trigger_failover(mode: "planned")).to be false
    end

    it "logs error when no suitable standby found" do
      expect(postgres_server).to receive(:is_representative).and_return(true)
      expect(postgres_server).to receive(:failover_target).and_return(nil)
      expect(Clog).to receive(:emit).with("No suitable standby found for failover", instance_of(Hash))
      expect(postgres_server.trigger_failover(mode: "planned")).to be false
    end

    it "returns true only when failover is successfully triggered" do
      standby = described_class.create(
        timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "standby").id,
        synchronization_status: "ready", timeline_access: "fetch", version: "16"
      )
      expect(postgres_server).to receive(:failover_target).and_return(standby)
      expect(standby).to receive(:incr_planned_take_over)
      expect(postgres_server.trigger_failover(mode: "planned")).to be true
    end
  end

  it "#read_replica?" do
    expect(postgres_server.resource).to receive(:read_replica?).and_return(true)
    expect(postgres_server).to be_read_replica
    expect(postgres_server.resource).to receive(:read_replica?).and_return(false)
    expect(postgres_server).not_to be_read_replica
  end

  describe "#failover_target" do
    before do
      postgres_server.is_representative = true
      allow(postgres_server).to receive(:read_replica?).and_return(false)
      allow(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", is_representative: false, strand: instance_double(Strand, label: "wait_catch_up"), needs_recycling?: false, read_replica?: false, physical_slot_ready: true, synchronization_status: "ready"),
        instance_double(described_class, ubid: "pgubidstandby2", is_representative: false, current_lsn: "1/5", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: false, physical_slot_ready: true, synchronization_status: "ready"),
        instance_double(described_class, ubid: "pgubidstandby3", is_representative: false, current_lsn: "1/10", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: false, physical_slot_ready: true, synchronization_status: "ready")
      ])
    end

    it "returns nil if there is no standby" do
      expect(resource).to receive(:servers).and_return([postgres_server]).at_least(:once)
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if there is no fresh standby" do
      expect(postgres_server).to receive(:is_representative).and_return(true)
      standby_server = described_class.new { it.id = "c068cac7-ed45-82db-bf38-a003582b36ef" }
      expect(standby_server).to receive(:resource).at_least(:once).and_return(resource)
      expect(standby_server).to receive(:is_representative).and_return(false).at_least(:once)
      expect(standby_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(standby_server).to receive(:vm).and_return(instance_double(Vm, display_size: "standard-4", sshable: Sshable.new))

      expect(resource).to receive(:servers).and_return([postgres_server, standby_server]).at_least(:once)
      expect(resource).to receive(:target_vm_size).and_return("standard-2")
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns the standby with highest lsn in sync replication" do
      expect(postgres_server).to receive(:is_representative).and_return(true)
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::SYNC)
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby3")
    end

    it "returns nil if last_known_lsn in unknown for async replication" do
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::ASYNC)
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if no lsn_monitor for async replication" do
      resource.update(ha_type: PostgresResource::HaType::ASYNC)
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if lsn difference is too hign for async replication" do
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::ASYNC)
      POSTGRES_MONITOR_DB[:postgres_lsn_monitor].insert(postgres_server_id: postgres_server.id, last_known_lsn: "2/0")
      expect(postgres_server.failover_target).to be_nil
    ensure
      # POSTGRES_MONITOR_DB doesn't use transactional testing, so it must be manually cleaned up
      POSTGRES_MONITOR_DB[:postgres_lsn_monitor].where(postgres_server_id: postgres_server.id).delete
    end

    it "returns the standby with highest lsn if lsn difference is not high in async replication" do
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::ASYNC)
      POSTGRES_MONITOR_DB[:postgres_lsn_monitor].insert(postgres_server_id: postgres_server.id, last_known_lsn: "1/11")
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby3")
    ensure
      # POSTGRES_MONITOR_DB doesn't use transactional testing, so it must be manually cleaned up
      POSTGRES_MONITOR_DB[:postgres_lsn_monitor].where(postgres_server_id: postgres_server.id).delete
    end

    it "returns standby with physical_slot_ready false as fallback" do
      allow(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", is_representative: false, current_lsn: "1/10", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: false, physical_slot_ready: false, synchronization_status: "ready")
      ])
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::SYNC)
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby1")
    end

    it "prefers standby with physical_slot_ready true over higher lsn without" do
      allow(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", is_representative: false, current_lsn: "1/5", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: false, physical_slot_ready: true, synchronization_status: "ready"),
        instance_double(described_class, ubid: "pgubidstandby2", is_representative: false, current_lsn: "1/10", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: false, physical_slot_ready: false, synchronization_status: "ready")
      ])
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::SYNC)
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby1")
    end
  end

  describe "#failover_target read_replica" do
    before do
      expect(postgres_server).to receive(:is_representative).and_return(true)
      allow(postgres_server).to receive(:read_replica?).and_return(true)

      allow(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", is_representative: false, strand: instance_double(Strand, label: "wait_catch_up"), needs_recycling?: false, read_replica?: true, physical_slot_ready: true, synchronization_status: "ready"),
        instance_double(described_class, ubid: "pgubidstandby2", is_representative: false, current_lsn: "1/5", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: true, physical_slot_ready: true, synchronization_status: "ready"),
        instance_double(described_class, ubid: "pgubidstandby3", is_representative: false, current_lsn: "1/10", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: true, physical_slot_ready: true, synchronization_status: "ready")
      ])
    end

    it "returns nil if there is no replica to failover" do
      expect(resource).to receive(:servers).and_return([postgres_server]).at_least(:once)
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if there is no fresh read_replica" do
      replica_server = described_class.new { it.id = "c068cac7-ed45-82db-bf38-a003582b36ef" }
      expect(replica_server).to receive(:resource).at_least(:once).and_return(resource)
      expect(replica_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(replica_server).to receive(:vm).and_return(instance_double(Vm, display_size: "standard-4"))
      expect(resource).to receive(:servers).and_return([postgres_server, replica_server]).at_least(:once)
      expect(resource).to receive(:target_vm_size).and_return("standard-2")
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns the replica with highest lsn" do
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby3")
    end

    it "returns the replica even if physical_slot_ready is false" do
      allow(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", is_representative: false, current_lsn: "1/10", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: true, physical_slot_ready: false, synchronization_status: "ready")
      ])
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby1")
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
      parent_resource = PostgresResource.create(
        project:,
        name: "postgres-resource-parent",
        ha_type: PostgresResource::HaType::NONE,
        user_config: {},
        pgbouncer_user_config: {},
        location:,
        target_version: "16",
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        superuser_password: "super"
      )
      parent_vm = create_hosted_vm(project, private_subnet, "parent-vm")
      described_class.create(
        timeline:, resource: parent_resource, vm_id: parent_vm.id, is_representative: true,
        synchronization_status: "ready", timeline_access: "push", version: "16"
      )

      resource.update(parent: parent_resource)
      postgres_server.update(timeline_access: "fetch")
      allow(resource.parent.representative_server).to receive(:current_lsn).and_return("F/F")
    end

    it "returns true if the diff is less than 80MB" do
      expect(postgres_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true if read replica and the parent representative server is nil" do
      postgres_server.resource.representative_server.update(is_representative: false)
      postgres_server.resource.update(restore_target: Time.now)
      expect(postgres_server.resource.representative_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server).to receive(:_run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true if read replica and the parent is nil" do
      postgres_server.resource.update(parent_id: PostgresResource.generate_ubid.to_uuid)
      expect(postgres_server.read_replica?).to be(true)
      expect(postgres_server.lsn_caught_up).to be(true)
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

    it "returns true when no representative server" do
      expect(postgres_server).to receive(:read_replica?).and_return(false)
      postgres_server.update(is_representative: false)
      expect(postgres_server.lsn_caught_up).to be(true)
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

  it "checks pulse" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate,
      db_connection: DB
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(postgres_server).not_to receive(:incr_checkup)
    expect(postgres_server).to receive(:primary?).and_return(false)
    expect(postgres_server).to receive(:standby?).and_return(false)

    postgres_server.check_pulse(session:, previous_pulse: pulse)
  end

  it "increments checkup semaphore if pulse is down for a while and the resource is not upgrading" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate,
      db_connection: instance_double(Sequel::Postgres::Database)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(session[:db_connection]).to receive(:get).and_raise(Sequel::DatabaseConnectionError)
    expect(postgres_server).to receive(:reload).and_return(postgres_server)
    expect(postgres_server).to receive(:incr_checkup)
    expect(postgres_server).to receive(:primary?).and_return(false)
    expect(postgres_server).to receive(:standby?).and_return(true)
    postgres_server.check_pulse(session:, previous_pulse: pulse)
  end

  it "uses pg_current_wal_lsn to track lsn for primaries" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate,
      db_connection: instance_double(Sequel::Postgres::Database)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(session[:db_connection]).to receive(:get).with(Sequel.function("pg_current_wal_lsn").as(:lsn)).and_raise(Sequel::DatabaseConnectionError)
    expect(postgres_server).to receive(:primary?).and_return(true)

    expect(postgres_server).to receive(:reload).and_return(postgres_server)
    expect(postgres_server).to receive(:incr_checkup)
    postgres_server.check_pulse(session:, previous_pulse: pulse)
  end

  it "uses pg_last_wal_replay_lsn to track lsn for read replicas" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate,
      db_connection: instance_double(Sequel::Postgres::Database)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(session[:db_connection]).to receive(:get).with(Sequel.function("pg_last_wal_replay_lsn").as(:lsn)).and_raise(Sequel::DatabaseConnectionError)
    expect(postgres_server).to receive(:primary?).and_return(false)
    expect(postgres_server).to receive(:standby?).and_return(false)

    expect(postgres_server).to receive(:reload).and_return(postgres_server)
    expect(postgres_server).to receive(:incr_checkup)
    postgres_server.check_pulse(session:, previous_pulse: pulse)
  end

  it "catches Sequel::Error if updating last known lsn fails" do
    expect(Clog).to receive(:emit).with("Failed to update last known lsn", instance_of(Hash)).and_call_original
    expect(postgres_server).to receive(:primary?).and_return(true)
    expect(postgres_server).to receive(:update_last_known_lsn).and_raise(Sequel::Error)
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
      expect(postgres_server).to receive(:strand).and_return(instance_double(Strand, label: "taking_over"))
      expect(postgres_server.taking_over?).to be true
    end

    it "returns false if the strand label is not 'wait'" do
      expect(postgres_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(postgres_server.taking_over?).to be false
    end
  end

  describe "#switch_to_new_timeline" do
    it "switches to new timeline with current parent" do
      expect(Prog::Postgres::PostgresTimelineNexus).to receive(:assemble).and_return(instance_double(PostgresTimeline, id: "1ff21ff9-7534-4d28-820b-1da97199e39e"))
      expect(postgres_server).to receive(:update).with(timeline_id: "1ff21ff9-7534-4d28-820b-1da97199e39e", timeline_access: "push")
      expect { postgres_server.switch_to_new_timeline }.not_to raise_error
    end

    it "switches to new timeline without current parent" do
      expect(Prog::Postgres::PostgresTimelineNexus).to receive(:assemble).and_return(instance_double(PostgresTimeline, id: "98637404-a37b-4991-a70f-1b7e3ffcbf31"))
      expect(postgres_server).to receive(:update).with(timeline_id: "98637404-a37b-4991-a70f-1b7e3ffcbf31", timeline_access: "push")
      expect { postgres_server.switch_to_new_timeline(parent_id: nil) }.not_to raise_error
    end

    it "configure new timeline on AWS" do
      location.update(provider: "aws")
      expect(Prog::Postgres::PostgresTimelineNexus).to receive(:assemble).and_return(instance_double(PostgresTimeline, id: "1ff21ff9-7534-4d28-820b-1da97199e39e"))
      expect(postgres_server).to receive(:update).with(timeline_id: "1ff21ff9-7534-4d28-820b-1da97199e39e", timeline_access: "push")
      expect(postgres_server).to receive(:incr_configure_s3_new_timeline)
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl stop wal-g")
      expect(postgres_server).to receive(:refresh_walg_credentials)
      expect { postgres_server.switch_to_new_timeline }.not_to raise_error
    end
  end

  describe "#refresh_walg_credentials" do
    it "does nothing if timeline has no blob storage" do
      expect(postgres_server.timeline.blob_storage).to be_nil
      expect(vm.sshable).not_to receive(:_cmd)
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end

    it "refreshes walg credentials if timeline has blob storage not on aws" do
      expect(timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, root_certs: "root_certs")).at_least(:once)
      expect(timeline).to receive(:generate_walg_config).and_return("walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "root_certs")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl restart wal-g")
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end

    it "refreshes walg credentials if timeline has blob storage on aws" do
      location.update(provider: "aws")
      expect(timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, root_certs: "root_certs")).at_least(:once)
      expect(timeline).to receive(:generate_walg_config).and_return("walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg_config")
      expect(postgres_server.vm.sshable).not_to receive(:_cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "root_certs")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl restart wal-g")
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end

    it "does not restart wal-g if use_old_walg_command_set is true" do
      expect(postgres_server.resource).to receive(:use_old_walg_command_set?).and_return(true)
      expect(timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, root_certs: "root_certs")).at_least(:once)
      expect(timeline).to receive(:generate_walg_config).and_return("walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "root_certs")
      expect(postgres_server.vm.sshable).not_to receive(:_cmd).with("sudo systemctl restart wal-g")
      expect { postgres_server.refresh_walg_credentials }.not_to raise_error
    end
  end

  describe "#export_metrics" do
    let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }
    let(:tsdb_client) { instance_double(VictoriaMetrics::Client) }

    it "calls observe_archival_backlog, observe_metrics_backlog, and observe_disk_usage at export counts where count % 12 == 1" do
      session[:export_count] = 12
      allow(postgres_server).to receive(:scrape_endpoints).and_return([])
      expect(postgres_server).to receive(:observe_archival_backlog).with(session)
      expect(postgres_server).to receive(:observe_metrics_backlog).with(session)
      expect(postgres_server).to receive(:observe_disk_usage).with(session)

      postgres_server.export_metrics(session:, tsdb_client:)
    end

    it "does not call observe methods when count % 12 != 1" do
      session[:export_count] = 2
      allow(postgres_server).to receive(:scrape_endpoints).and_return([])
      expect(postgres_server).not_to receive(:observe_archival_backlog)
      expect(postgres_server).not_to receive(:observe_metrics_backlog)
      expect(postgres_server).not_to receive(:observe_disk_usage)

      postgres_server.export_metrics(session:, tsdb_client:)
    end

    it "increments export_count in session" do
      allow(postgres_server).to receive(:observe_archival_backlog).with(session)
      allow(postgres_server).to receive(:observe_metrics_backlog).with(session)
      allow(postgres_server).to receive(:observe_disk_usage).with(session)
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
      allow(postgres_server).to receive(:archival_backlog_threshold).and_return(10)
    end

    it "checks archival backlog and does nothing if it is within limits" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_return("5\n")
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect(Page).to receive(:from_tag_parts).with("PGArchivalBacklogHigh", postgres_server.id).and_return(nil)

      postgres_server.observe_archival_backlog(session)
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

      postgres_server.observe_archival_backlog(session)
    end

    it "checks archival backlog and resolves a page if it is back within limits" do
      existing_page = instance_double(Page)
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l"
      ).and_return("3\n")
      expect(Page).to receive(:from_tag_parts).with("PGArchivalBacklogHigh", postgres_server.id).and_return(existing_page)
      expect(existing_page).to receive(:incr_resolve)

      postgres_server.observe_archival_backlog(session)
    end

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
      allow(postgres_server).to receive(:storage_size_gib).and_return(1024)
      expect(postgres_server.archival_backlog_threshold).to eq(1000)
    end

    it "returns smaller threshold for smaller storage sizes" do
      allow(postgres_server).to receive(:storage_size_gib).and_return(100)
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

  describe "#observe_disk_usage" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    it "increments check_disk_usage on the resource when primary and usage >= 77%" do
      Strand.create_with_id(resource, prog: "Postgres::PostgresResourceNexus", label: "wait")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  80%\n")
      postgres_server.observe_disk_usage(session)
      expect(Semaphore.where(strand_id: resource.strand.id, name: "check_disk_usage").count).to eq(1)
    end

    it "does nothing when primary and usage < 77% and no prior auto-scale action" do
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  50%\n")
      expect(resource).not_to receive(:incr_check_disk_usage)
      postgres_server.observe_disk_usage(session)
    end

    it "increments check_disk_usage when primary and usage < 77% but storage_auto_scale_action_performed_80 is set" do
      Strand.create_with_id(resource, prog: "Postgres::PostgresResourceNexus", label: "wait")
      resource.incr_storage_auto_scale_action_performed_80
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  50%\n")
      postgres_server.observe_disk_usage(session)
      expect(Semaphore.where(strand_id: resource.strand.id, name: "check_disk_usage").count).to eq(1)
    end

    it "does not duplicate check_disk_usage semaphore when already set on primary" do
      Strand.create_with_id(resource, prog: "Postgres::PostgresResourceNexus", label: "wait")
      resource.incr_check_disk_usage
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  80%\n")
      postgres_server.observe_disk_usage(session)
      expect(Semaphore.where(strand_id: resource.strand.id, name: "check_disk_usage").count).to eq(1)
    end

    it "creates a page for non-primary server with usage >= 95%" do
      postgres_server.update(is_representative: false, timeline_access: "fetch")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  96%\n")
      expect(Prog::PageNexus).to receive(:assemble).with(
        "High disk usage on non-primary PG server (96%)",
        ["PGDiskUsageHigh", postgres_server.id],
        postgres_server.ubid,
        severity: "warning",
        extra_data: {disk_usage_percent: 96}
      )
      postgres_server.observe_disk_usage(session)
    end

    it "resolves PGDiskUsageHigh page for non-primary server with usage < 95%" do
      postgres_server.update(is_representative: false, timeline_access: "fetch")
      page = Prog::PageNexus.assemble("High disk usage on non-primary PG server", ["PGDiskUsageHigh", postgres_server.id], postgres_server.ubid, severity: "warning")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")
      postgres_server.observe_disk_usage(session)
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
    end

    it "does nothing for non-primary server with usage < 95% and no existing page" do
      postgres_server.update(is_representative: false, timeline_access: "fetch")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect(resource).not_to receive(:incr_check_disk_usage)
      postgres_server.observe_disk_usage(session)
    end

    it "logs errors when checking disk usage fails" do
      expect(session[:ssh_session]).to receive(:_exec!).and_raise(Net::SSH::Exception.new("SSH error"))
      expect(Clog).to receive(:emit).with("Failed to observe disk usage", instance_of(Hash)).and_call_original
      postgres_server.observe_disk_usage(session)
    end
  end

  if Config.unfrozen_test?
    describe "#attach_s3_policy_if_needed" do
      it "calls attach_role_policy when needs s3 policy attachment" do
        location.update(provider: "aws")
        expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
        AwsInstance.create_with_id(vm, iam_role: "role")
        iam_client = Aws::IAM::Client.new(stub_responses: true)
        LocationCredential.create(location:, assume_role: "role")

        expect(postgres_server.timeline.location.location_credential).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
        expect(postgres_server.timeline.location.location_credential).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:attach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.aws_s3_policy_arn)
        postgres_server.attach_s3_policy_if_needed
      end

      it "detaches parent timeline when Config.aws_postgres_iam_access set" do
        location.update(provider: "aws")
        expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
        AwsInstance.create_with_id(vm, iam_role: "role")
        iam_client = Aws::IAM::Client.new(stub_responses: true)
        LocationCredential.create(location:, assume_role: "role")

        parent = PostgresTimeline.create(location:)
        timeline.update(parent:)
        expect(postgres_server.timeline.location.location_credential).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
        expect(postgres_server.timeline.location.location_credential).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:attach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.aws_s3_policy_arn)
        expect(iam_client).to receive(:detach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.parent.aws_s3_policy_arn)
        postgres_server.attach_s3_policy_if_needed
      end

      it "does not detach parent timeline when Config.aws_postgres_iam_access not set" do
        location.update(provider: "aws")
        AwsInstance.create_with_id(vm, iam_role: "role")
        LocationCredential.create(location:, assume_role: "role")

        expect(postgres_server.vm.aws_instance).not_to receive(:iam_role)
        postgres_server.attach_s3_policy_if_needed
      end

      it "does not call attach_role_policy when needs s3 policy attachment" do
        LocationCredential.create(location:, assume_role: "role")
        expect(postgres_server.timeline.location.location_credential).not_to receive(:aws_iam_account_id)
        postgres_server.attach_s3_policy_if_needed
      end
    end
  end

  describe "#run_query" do
    it "raises if given interpolated string" do
      string = "string"
      expect { postgres_server.run_query("interpolated #{string}") }.to raise_error(NetSsh::PotentialInsecurity)
    end
  end
end
