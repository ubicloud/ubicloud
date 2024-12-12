# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresServer do
  subject(:postgres_server) {
    described_class.new { _1.id = "c068cac7-ed45-82db-bf38-a003582b36ee" }
  }

  let(:resource) {
    instance_double(
      PostgresResource,
      representative_server: postgres_server,
      identity: "pgubid.postgres.ubicloud.com",
      ha_type: PostgresResource::HaType::NONE
    )
  }

  let(:vm) {
    instance_double(
      Vm,
      sshable: instance_double(Sshable),
      mem_gib: 8,
      ephemeral_net4: "1.2.3.4",
      ephemeral_net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64"),
      private_subnets: [
        instance_double(
          PrivateSubnet,
          net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
          net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64")
        )
      ],
      nics: [
        instance_double(Nic, private_ipv4: NetAddr::IPv4Net.parse("10.70.205.205/32"))
      ]
    )
  }

  before do
    allow(postgres_server).to receive_messages(resource: resource, vm: vm)
  end

  describe "#configure" do
    before do
      allow(postgres_server).to receive(:timeline).and_return(instance_double(PostgresTimeline, blob_storage: "dummy-blob-storage"))
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
    it "fails if server is not primary" do
      expect(postgres_server).to receive(:primary?).and_return(false)
      expect(postgres_server.trigger_failover).to be_falsey
    end

    it "fails if there is no suitable standby" do
      expect(postgres_server).to receive(:primary?).and_return(true)
      expect(postgres_server).to receive(:failover_target).and_return(nil)
      expect(postgres_server.trigger_failover).to be_falsey
    end

    it "increments take over semaphore and destroy semaphore" do
      standby = instance_double(described_class)
      expect(postgres_server).to receive(:primary?).and_return(true)
      expect(postgres_server).to receive(:failover_target).and_return(standby)
      expect(standby).to receive(:incr_take_over)
      expect(postgres_server).to receive(:incr_destroy)
      expect(postgres_server.trigger_failover).to be_truthy
    end
  end

  describe "#failover_target" do
    before do
      postgres_server.timeline_access = "push"
      allow(resource).to receive(:servers).and_return([
        postgres_server,
        instance_double(described_class, ubid: "pgubidstandby1", standby?: true, strand: instance_double(Strand, label: "wait_catch_up")),
        instance_double(described_class, ubid: "pgubidstandby2", standby?: true, run_query: "1/5", strand: instance_double(Strand, label: "wait")),
        instance_double(described_class, ubid: "pgubidstandby3", standby?: true, run_query: "1/10", strand: instance_double(Strand, label: "wait"))
      ])
    end

    it "returns nil if there is no standby" do
      expect(resource).to receive(:servers).and_return([postgres_server]).at_least(:once)
      expect(postgres_server.failover_target).to be_nil
    end

    it "returns the standby with highest lsn in sync replication" do
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

  it "initiates a new health monitor session" do
    forward = instance_double(Net::SSH::Service::Forward)
    expect(forward).to receive(:local_socket)
    session = instance_double(Net::SSH::Connection::Session)
    expect(session).to receive(:forward).and_return(forward)
    expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(session)
    postgres_server.init_health_monitor_session
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

  it "catches Sequel::Error if updating PostgresLsnMonitor fails" do
    lsn_monitor = instance_double(PostgresLsnMonitor, last_known_lsn: "1/5")
    expect(PostgresLsnMonitor).to receive(:new).and_return(lsn_monitor)
    expect(lsn_monitor).to receive(:insert_conflict).and_return(lsn_monitor)
    expect(lsn_monitor).to receive(:save_changes).and_raise(Sequel::Error)
    expect(Clog).to receive(:emit).with("Failed to update PostgresLsnMonitor")

    postgres_server.check_pulse(session: {db_connection: DB}, previous_pulse: {})
  end

  it "runs query on vm" do
    expect(postgres_server.vm.sshable).to receive(:cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv", stdin: "SELECT 1").and_return("1\n")
    expect(postgres_server.run_query("SELECT 1")).to eq("1")
  end
end
