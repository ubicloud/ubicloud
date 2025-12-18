# frozen_string_literal: true

require "logger"
require_relative "../../common/lib/util"
require_relative "../lib/postgres_lockout"

RSpec.describe PostgresLockout do
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }
  let(:lockout) { described_class.new("17", logger) }

  before do
    allow(lockout).to receive(:r)
  end

  describe ".lockout_pg_hba" do
    it "returns restrictive pg_hba configuration" do
      config = described_class.lockout_pg_hba

      expect(config).to include("LOCKOUT MODE")
      expect(config).to include("local   all             postgres")
      expect(config).to include("local   all             ubi_monitoring")
      expect(config).to include("hostssl replication     ubi_replication all")
    end
  end

  describe "#terminate_external_connections" do
    it "terminates connections except ubi_replication and current session" do
      expect(logger).to receive(:info)
        .with("Terminating all existing connections except for the current session and ubi_replication user...")
      expect(lockout).to receive(:r)
        .with('sudo -u postgres psql -c "SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity WHERE usename != \'ubi_replication\' AND pid <> pg_catalog.pg_backend_pid();"')

      lockout.terminate_external_connections
    end
  end

  describe "#lockout" do
    it "writes lockout pg_hba and terminates connections in order" do
      expect(lockout).to receive(:write_lockout_pg_hba).ordered
      expect(lockout).to receive(:terminate_external_connections).ordered
      expect(logger).to receive(:info)
        .with("PostgreSQL 17 is now in lockout mode - only UNIX socket connections and ubi_replication are allowed.")

      lockout.lockout
    end
  end
end
