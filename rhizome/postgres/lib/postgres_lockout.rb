# frozen_string_literal: true

require_relative "../../common/lib/util"

class PostgresLockout
  def initialize(version, logger)
    @version = Integer(version)
    @logger = logger
  end

  def self.lockout_pg_hba
    # pg_hba.conf that only allows UNIX socket connections
    # and connections from ubi_replication user
    <<-PG_HBA
# PostgreSQL Client Authentication Configuration File - LOCKOUT MODE
# ================================================================
#
# This configuration restricts connections to UNIX sockets only
# and ubi_replication user for replication.

# TYPE  DATABASE        USER            ADDRESS                 METHOD
# Database administrative login by Unix domain socket
local   all             postgres                                peer map=system2postgres

# Allow connections from localhost with ubi_monitoring OS user as
# ubi_monitoring database user. This will be used by postgres_exporter
# to scrape metrics and expose them to prometheus.
local   all             ubi_monitoring                          peer

# Allow replication connection using special replication user for
# HA standbys (SSL connections from ubi_replication user only)
hostssl replication     ubi_replication all                     cert map=standby2replication
    PG_HBA
  end

  def write_lockout_pg_hba
    safe_write_to_file("/etc/postgresql/#{@version}/main/pg_hba.conf", PostgresLockout.lockout_pg_hba)
    @logger.info("Written lockout pg_hba.conf for PostgreSQL #{@version}")
    r "sudo pg_ctlcluster #{@version} main reload"
    @logger.info("Reloaded PostgreSQL #{@version} configuration to apply lockout pg_hba.conf")
  end

  def terminate_external_connections
    @logger.info("Terminating all existing connections except for the current session and ubi_replication user...")
    r "sudo -u postgres psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename != 'ubi_replication' AND pid <> pg_backend_pid();\""
  end

  def apply_nftables_lockout
    @logger.info("Applying nftables rules to block PostgreSQL ports (5432, 6432)...")
    nftables_config = <<~NFTABLES
      table inet pg_fence;
      delete table inet pg_fence;
      table inet pg_fence {
        chain input {
          type filter hook input priority 0; policy accept;
          tcp dport { 5432, 6432 } drop
        }
      }
    NFTABLES

    IO.popen(["sudo", "nft", "--file", "-"], "w") do |io|
      io.write(nftables_config)
    end

    if $?.success?
      @logger.info("Successfully applied nftables lockout rules")
    else
      @logger.error("Failed to apply nftables lockout rules")
    end
  end

  def lockout
    write_lockout_pg_hba
    terminate_external_connections
    apply_nftables_lockout
    @logger.info("PostgreSQL #{@version} is now in lockout mode - only UNIX socket connections and ubi_replication are allowed.")
  end
end
