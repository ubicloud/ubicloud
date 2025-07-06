# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresServer do
  subject(:postgres_server) {
    described_class.new { it.id = "c068cac7-ed45-82db-bf38-a003582b36ee" }
  }

  let(:resource) {
    instance_double(
      PostgresResource,
      representative_server: postgres_server,
      identity: "pgubid.postgres.ubicloud.com",
      ha_type: PostgresResource::HaType::NONE,
      user_config: {},
      pgbouncer_user_config: {}
    )
  }

  let(:vm) {
    instance_double(
      Vm,
      sshable: instance_double(Sshable),
      vcpus: 4,
      memory_gib: 8,
      ephemeral_net4: "1.2.3.4",
      ip6: "fdfa:b5aa:14a3:4a3d::2",
      private_subnets: [
        instance_double(
          PrivateSubnet,
          net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
          net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64")
        )
      ],
      nics: [
        instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.70.205.205/32"))
      ],
      private_ipv4: NetAddr::IPv4Net.parse("10.70.205.205/32").network,
      location: instance_double(Location, aws?: false)
    )
  }

  before do
    allow(postgres_server).to receive_messages(resource: resource, vm: vm)
  end

  describe "#configure" do
    before do
      allow(postgres_server).to receive_messages(timeline: instance_double(PostgresTimeline, blob_storage: "dummy-blob-storage"), read_replica?: false)
      allow(resource).to receive(:flavor).and_return(PostgresResource::Flavor::STANDARD)
    end

    it "does not set archival related configs if blob storage is not configured" do
      expect(postgres_server).to receive(:timeline).and_return(instance_double(PostgresTimeline, blob_storage: nil))
      expect(postgres_server.configure_hash[:configs]).not_to include(:archive_mode, :archive_timeout, :archive_command, :synchronous_standby_names, :primary_conninfo, :recovery_target_time, :restore_command)
    end

    it "sets configs that are specific to primary" do
      postgres_server.timeline_access = "push"
      expect(postgres_server.configure_hash[:configs]).to include(:archive_mode, :archive_timeout, :archive_command)
    end

    it "sets synchronous_standby_names for sync replication mode" do
      postgres_server.timeline_access = "push"
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::SYNC)
      expect(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", standby?: true, synchronization_status: "catching_up"),
        instance_double(described_class, ubid: "pgubidstandby2", standby?: true, synchronization_status: "ready")
      ])

      expect(postgres_server.configure_hash[:configs]).to include(synchronous_standby_names: "'ANY 1 (pgubidstandby2)'")
    end

    it "sets synchronous_standby_names as empty if there is no caught up standby" do
      postgres_server.timeline_access = "push"
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::SYNC)
      expect(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", standby?: true, synchronization_status: "catching_up"),
        instance_double(described_class, ubid: "pgubidstandby2", standby?: true, synchronization_status: "catching_up")
      ])

      expect(postgres_server.configure_hash[:configs]).not_to include(:synchronous_standby_names)
    end

    it "sets configs that are specific to standby" do
      postgres_server.timeline_access = "fetch"
      expect(postgres_server).to receive(:doing_pitr?).and_return(false).at_least(:once)
      expect(resource).to receive(:replication_connection_string)
      expect(postgres_server.configure_hash[:configs]).to include(:primary_conninfo, :restore_command)
    end

    it "sets configs that are specific to restoring servers" do
      postgres_server.timeline_access = "fetch"
      expect(resource).to receive(:restore_target)
      expect(postgres_server.configure_hash[:configs]).to include(:recovery_target_time, :restore_command)
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
  end

  describe "#trigger_failover" do
    it "logs error when server is not primary" do
      expect(postgres_server).to receive(:representative_at).and_return(nil)
      expect(Clog).to receive(:emit).with("Cannot trigger failover on a non-representative server")
      expect(postgres_server.trigger_failover).to be false
    end

    it "logs error when no suitable standby found" do
      expect(postgres_server).to receive(:representative_at).and_return(Time.now)
      expect(postgres_server).to receive(:failover_target).and_return(nil)
      expect(Clog).to receive(:emit).with("No suitable standby found for failover")
      expect(postgres_server.trigger_failover).to be false
    end

    it "returns true only when failover is successfully triggered" do
      standby = instance_double(described_class)
      expect(postgres_server).to receive(:representative_at).and_return(Time.now)
      expect(postgres_server).to receive(:failover_target).and_return(standby)
      expect(standby).to receive(:incr_take_over)
      expect(postgres_server.trigger_failover).to be true
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
      postgres_server.representative_at = Time.now
      allow(postgres_server).to receive(:read_replica?).and_return(false)
      allow(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", representative_at: nil, strand: instance_double(Strand, label: "wait_catch_up"), needs_recycling?: false, read_replica?: false),
        instance_double(described_class, ubid: "pgubidstandby2", representative_at: nil, current_lsn: "1/5", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: false),
        instance_double(described_class, ubid: "pgubidstandby3", representative_at: nil, current_lsn: "1/10", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: false)
      ])
    end

    it "returns nil if there is no standby" do
      expect(resource).to receive(:servers).and_return([postgres_server]).at_least(:once)
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if there is no fresh standby" do
      expect(postgres_server).to receive(:representative_at).and_return(Time.now)
      standby_server = described_class.new { it.id = "c068cac7-ed45-82db-bf38-a003582b36ef" }
      expect(standby_server).to receive(:resource).and_return(resource)
      expect(standby_server).to receive(:representative_at).and_return(nil).at_least(:once)
      expect(standby_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(standby_server).to receive(:vm).and_return(instance_double(Vm, display_size: "standard-4", sshable: instance_double(Sshable)))

      expect(resource).to receive(:servers).and_return([postgres_server, standby_server]).at_least(:once)
      expect(resource).to receive(:target_vm_size).and_return("standard-2")
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns the standby with highest lsn in sync replication" do
      expect(postgres_server).to receive(:representative_at).and_return(Time.now)
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::SYNC)
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby3")
    end

    it "returns nil if last_known_lsn in unknown for async replication" do
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::ASYNC)
      expect(postgres_server).to receive(:lsn_monitor).and_return(instance_double(PostgresLsnMonitor, last_known_lsn: nil))
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if lsn difference is too hign for async replication" do
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::ASYNC)
      expect(postgres_server).to receive(:lsn_monitor).and_return(instance_double(PostgresLsnMonitor, last_known_lsn: "2/0")).twice
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns the standby with highest lsn if lsn difference is not high in async replication" do
      expect(resource).to receive(:ha_type).and_return(PostgresResource::HaType::ASYNC)
      expect(postgres_server).to receive(:lsn_monitor).and_return(instance_double(PostgresLsnMonitor, last_known_lsn: "1/11")).twice
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby3")
    end
  end

  describe "#failover_target read_replica" do
    before do
      expect(postgres_server).to receive(:representative_at).and_return(Time.now)
      allow(postgres_server).to receive(:read_replica?).and_return(true)

      allow(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", representative_at: nil, strand: instance_double(Strand, label: "wait_catch_up"), needs_recycling?: false, read_replica?: true),
        instance_double(described_class, ubid: "pgubidstandby2", representative_at: nil, current_lsn: "1/5", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: true),
        instance_double(described_class, ubid: "pgubidstandby3", representative_at: nil, current_lsn: "1/10", strand: instance_double(Strand, label: "wait"), needs_recycling?: false, read_replica?: true)
      ])
    end

    it "returns nil if there is no replica to failover" do
      expect(resource).to receive(:servers).and_return([postgres_server]).at_least(:once)
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns nil if there is no fresh read_replica" do
      replica_server = described_class.new { it.id = "c068cac7-ed45-82db-bf38-a003582b36ef" }
      expect(replica_server).to receive(:resource).and_return(resource)
      expect(replica_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(replica_server).to receive(:vm).and_return(instance_double(Vm, display_size: "standard-4"))
      expect(resource).to receive(:servers).and_return([postgres_server, replica_server]).at_least(:once)
      expect(resource).to receive(:target_vm_size).and_return("standard-2")
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns the replica with highest lsn" do
      expect(postgres_server.failover_target.ubid).to eq("pgubidstandby3")
    end
  end

  describe "storage_size_gib" do
    it "returns the storage size in GiB" do
      volume_dataset = instance_double(Sequel::Dataset)
      expect(volume_dataset).to receive(:reject).and_return([instance_double(VmStorageVolume, boot: false, size_gib: 64)])
      expect(vm).to receive(:vm_storage_volumes_dataset).and_return(volume_dataset)
      expect(postgres_server.storage_size_gib).to eq(64)
    end

    it "returns nil if there is no storage volume" do
      volume_dataset = instance_double(Sequel::Dataset)
      expect(volume_dataset).to receive(:reject).and_return([])
      expect(vm).to receive(:vm_storage_volumes_dataset).and_return(volume_dataset)
      expect(postgres_server.storage_size_gib).to be_zero
    end
  end

  describe "lsn_caught_up" do
    let(:parent_resource) {
      instance_double(PostgresResource, representative_server: instance_double(described_class, current_lsn: "F/F"))
    }

    before do
      allow(resource).to receive(:parent).and_return(parent_resource)
    end

    it "returns true if the diff is less than 80MB" do
      expect(postgres_server).to receive(:read_replica?).and_return(true)
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true if read replica and the parent representative server is nil" do
      expect(postgres_server).to receive(:read_replica?).and_return(true)
      expect(parent_resource).to receive(:representative_server).and_return(nil)
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F").twice
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns true if read replica and the parent is nil" do
      expect(postgres_server).to receive(:read_replica?).and_return(true)
      expect(postgres_server.resource).to receive(:parent).and_return(nil)
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F").twice
      expect(postgres_server.lsn_caught_up).to be_truthy
    end

    it "returns false if the diff is less than 80MB" do
      expect(postgres_server).to receive(:read_replica?).and_return(true)
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("1/00000000")
      expect(postgres_server.lsn_caught_up).to be_falsey
    end

    it "returns true if the diff is less than 80MB for not read replica and uses the main representative server" do
      expect(postgres_server).to receive(:read_replica?).and_return(false)
      expect(resource).to receive(:representative_server).and_return(postgres_server)
      expect(postgres_server).to receive(:run_query).with("SELECT pg_last_wal_replay_lsn()").and_return("F/F", "F/F")
      expect(postgres_server.lsn_caught_up).to be_truthy
    end
  end

  it "initiates a new health monitor session" do
    forward = instance_double(Net::SSH::Service::Forward)
    expect(forward).to receive(:local_socket)
    session = instance_double(Net::SSH::Connection::Session)
    expect(session).to receive(:forward).and_return(forward)
    expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(session)
    postgres_server.init_health_monitor_session
  end

  it "initiates a new metrics export session" do
    session = instance_double(Net::SSH::Connection::Session)
    expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(session)
    postgres_server.init_metrics_export_session
  end

  it "checks pulse" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
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

    postgres_server.check_pulse(session: session, previous_pulse: pulse)
  end

  it "increments checkup semaphore if pulse is down for a while" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
      db_connection: instance_double(Sequel::Postgres::Database)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(session[:db_connection]).to receive(:[]).and_raise(Sequel::DatabaseConnectionError)
    expect(postgres_server).to receive(:reload).and_return(postgres_server)
    expect(postgres_server).to receive(:incr_checkup)
    expect(postgres_server).to receive(:primary?).and_return(false)
    expect(postgres_server).to receive(:standby?).and_return(true)
    postgres_server.check_pulse(session: session, previous_pulse: pulse)
  end

  it "uses pg_current_wal_lsn to track lsn for primaries" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
      db_connection: instance_double(Sequel::Postgres::Database)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(session[:db_connection]).to receive(:[]).with("SELECT pg_current_wal_lsn() AS lsn").and_raise(Sequel::DatabaseConnectionError)
    expect(postgres_server).to receive(:primary?).and_return(true)

    expect(postgres_server).to receive(:reload).and_return(postgres_server)
    expect(postgres_server).to receive(:incr_checkup)
    postgres_server.check_pulse(session: session, previous_pulse: pulse)
  end

  it "uses pg_last_wal_replay_lsn to track lsn for read replicas" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
      db_connection: instance_double(Sequel::Postgres::Database)
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30
    }

    expect(session[:db_connection]).to receive(:[]).with("SELECT pg_last_wal_replay_lsn() AS lsn").and_raise(Sequel::DatabaseConnectionError)
    expect(postgres_server).to receive(:primary?).and_return(false)
    expect(postgres_server).to receive(:standby?).and_return(false)

    expect(postgres_server).to receive(:reload).and_return(postgres_server)
    expect(postgres_server).to receive(:incr_checkup)
    postgres_server.check_pulse(session: session, previous_pulse: pulse)
  end

  it "catches Sequel::Error if updating PostgresLsnMonitor fails" do
    lsn_monitor = instance_double(PostgresLsnMonitor, last_known_lsn: "1/5")
    expect(PostgresLsnMonitor).to receive(:new).and_return(lsn_monitor)
    expect(lsn_monitor).to receive(:insert_conflict).and_return(lsn_monitor)
    expect(lsn_monitor).to receive(:save_changes).and_raise(Sequel::Error)
    expect(Clog).to receive(:emit).with("Failed to update PostgresLsnMonitor").and_call_original
    expect(postgres_server).to receive(:primary?).and_return(true)
    postgres_server.check_pulse(session: {db_connection: DB}, previous_pulse: {})
  end

  it "runs query on vm" do
    expect(postgres_server.vm.sshable).to receive(:cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: "SELECT 1").and_return("1\n")
    expect(postgres_server.run_query("SELECT 1")).to eq("1")
  end

  it "returns the right storage_device_paths for AWS" do
    expect(postgres_server.vm.location).to receive(:aws?).and_return(true)
    expect(postgres_server.vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: true, device_path: "/dev/vda"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/nvme1n1"), instance_double(VmStorageVolume, boot: false, device_path: "/dev/nvme2n1")])
    expect(postgres_server.vm.sshable).to receive(:cmd).with("lsblk -b -d -o NAME,SIZE | sort -n -k2 | tail -n2 |  awk '{print \"/dev/\"$1}'").and_return("/dev/nvme1n1\n/dev/nvme2n1\n")
    expect(postgres_server.storage_device_paths).to eq(["/dev/nvme1n1", "/dev/nvme2n1"])
  end

  it "returns the right storage_device_paths for Hetzner" do
    expect(postgres_server.vm).to receive(:vm_storage_volumes).and_return([instance_double(VmStorageVolume, boot: false, device_path: "/dev/vdb")])
    expect(postgres_server.storage_device_paths).to eq(["/dev/vdb"])
  end
end
