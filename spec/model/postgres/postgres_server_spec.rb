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
      ]
    )
  }

  before do
    allow(postgres_server).to receive_messages(resource: resource, vm: vm)
  end

  describe "#configure" do
    before do
      allow(postgres_server).to receive(:timeline).and_return(instance_double(PostgresTimeline, blob_storage: "dummy-blob-storage"))
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

    expect(postgres_server).to receive(:incr_checkup)
    postgres_server.check_pulse(session: session, previous_pulse: pulse)
  end
end
