# frozen_string_literal: true

require_relative "../lib/standby_backup"

RSpec.describe StandbyBackup do
  let(:psql) { ["sudo", "-u", "postgres", "psql", "-XAt", "-c"] }
  let(:backup) { {"backup_name" => "base_000000020000000A00000010", "hostname" => "pg-host", "wal_file_name" => "000000020000000A00000010", "finish_lsn" => (0xA << 32) | 0x23000028} }
  let(:other_host_backup) { backup.merge("hostname" => "other", "finish_lsn" => (0xB << 32)) }
  let(:older_backup) { backup.merge("backup_name" => "base_old", "finish_lsn" => (0x9 << 32)) }
  let(:conninfo) { "postgres://ubi_replication@pg.private.example?sslcert=/etc/ssl/certs/client.crt&dbname=postgres" }

  def expect_walg(args, output = "")
    expect(described_class).to receive(:_run_command).with("sudo", "-u", "postgres", "wal-g", *args.split, "--config", "/etc/postgresql/wal-g.env").and_return(output)
  end

  def expect_primary(sql)
    expect(described_class).to receive(:_run_command).with("sudo", "-u", "postgres", "psql", "-XAt", "-d", conninfo, "-c", sql).ordered
  end

  describe ".run" do
    let(:backup_push) { ["sudo", "-u", "postgres", "wal-g", "backup-push", "/dat/18/data", "--config", "/etc/postgresql/wal-g.env", "--verify"] }

    def expect_in_recovery(answer)
      expect(described_class).to receive(:_run_command).with(*psql, "SELECT pg_catalog.pg_is_in_recovery()").and_return("#{answer}\n").ordered
    end

    def expect_start_prepared
      expect(described_class).to receive(:_run_command).with(*psql, "SELECT setting FROM pg_catalog.pg_settings WHERE name = 'primary_conninfo'").and_return("#{conninfo}\n").ordered
      expect(described_class).to receive(:checkpoint_primary_if_needed).with(conninfo).ordered
      expect(described_class).to receive(:wait_for_primary_checkpoint_replayed).with(conninfo).ordered
      expect(described_class).to receive(:_run_command).with(*psql, "CHECKPOINT").ordered
    end

    it "prepares the start, pushes the backup under the CPU weight, then waits for its end WAL" do
      expect_in_recovery("t")
      expect_start_prepared
      expect(described_class).to receive(:_run_command).with("systemd-run", "--scope", "--collect", "-p", "CPUWeight=25", *backup_push).ordered
      expect(described_class).to receive(:wait_for_end_wal_archived).with(conninfo).and_return(true).ordered

      described_class.run("18", "25")
    end

    it "pushes the backup without a scope when no CPU weight is given" do
      expect_in_recovery("t")
      expect_start_prepared
      expect(described_class).to receive(:_run_command).with(*backup_push).ordered
      expect(described_class).to receive(:wait_for_end_wal_archived).with(conninfo).and_return(true).ordered

      described_class.run("18")
    end

    it "deletes the backup and fails when its end WAL segment is not confirmed archived" do
      expect_in_recovery("t")
      expect_start_prepared
      expect(described_class).to receive(:_run_command).with(*backup_push).ordered
      expect(described_class).to receive(:wait_for_end_wal_archived).with(conninfo).and_return(false).ordered
      expect(Socket).to receive(:gethostname).and_return("pg-host")
      expect_walg("backup-list --detail --json", [older_backup, backup, other_host_backup].to_json)
      expect_walg("delete target base_000000020000000A00000010 --confirm")

      expect { described_class.run("18") }.to raise_error(RuntimeError, "base_000000020000000A00000010 deleted: its end WAL segment was not confirmed archived")
    end

    it "refuses to back up a server that is no longer a standby" do
      expect_in_recovery("f")
      expect(described_class).not_to receive(:checkpoint_primary_if_needed)

      expect { described_class.run("18", "25") }.to raise_error(RuntimeError, "Not in recovery; a primary backs up with take-backup")
    end
  end

  describe ".standby?" do
    it "is true when the server is in recovery" do
      expect(described_class).to receive(:_run_command).with(*psql, "SELECT pg_catalog.pg_is_in_recovery()").and_return("t\n")
      expect(described_class.standby?).to be(true)
    end

    it "is false on a primary" do
      expect(described_class).to receive(:_run_command).with(*psql, "SELECT pg_catalog.pg_is_in_recovery()").and_return("f\n")
      expect(described_class.standby?).to be(false)
    end
  end

  describe ".checkpoint_primary_if_needed" do
    let(:lag_sql) { "SELECT pg_catalog.pg_wal_lsn_diff(pg_catalog.pg_current_wal_lsn(), redo_lsn)::bigint FROM pg_catalog.pg_control_checkpoint()" }

    it "checkpoints a primary whose last checkpoint is stale" do
      expect_primary(lag_sql).and_return("#{2 * 1024 * 1024 * 1024}\n")
      expect_primary("CHECKPOINT").and_return("CHECKPOINT\n")

      described_class.checkpoint_primary_if_needed(conninfo)
    end

    it "leaves a primary whose last checkpoint is recent alone" do
      expect_primary(lag_sql).and_return("#{64 * 1024 * 1024}\n")

      described_class.checkpoint_primary_if_needed(conninfo)
    end

    it "warns when the primary refuses a checkpoint" do
      expect_primary(lag_sql).and_return("#{2 * 1024 * 1024 * 1024}\n")
      expect_primary("CHECKPOINT").and_raise(CommandFail.new("command failed: psql", "", "ERROR:  permission denied to execute CHECKPOINT command"))
      expect(described_class).to receive(:warn).with("Could not checkpoint the primary (ERROR:  permission denied to execute CHECKPOINT command); waiting on its last checkpoint").ordered

      described_class.checkpoint_primary_if_needed(conninfo)
    end

    it "warns when the primary cannot be reached" do
      expect_primary(lag_sql).and_raise(CommandFail.new("command failed: psql", "", "connection refused"))
      expect(described_class).to receive(:warn).with("Could not checkpoint the primary (connection refused); waiting on its last checkpoint").ordered

      described_class.checkpoint_primary_if_needed(conninfo)
    end
  end

  describe ".wait_for_primary_checkpoint_replayed" do
    let(:checkpoint_lsn_sql) { "SELECT checkpoint_lsn FROM pg_catalog.pg_control_checkpoint()" }

    def expect_replay(lsn)
      expect(described_class).to receive(:_run_command).with(*psql, "SELECT pg_catalog.pg_last_wal_replay_lsn()").and_return("#{lsn}\n").ordered
    end

    it "waits for the standby to replay past the primary's checkpoint" do
      expect_primary(checkpoint_lsn_sql).and_return("B/89000990\n")
      expect_replay("B/89000990")
      expect(described_class).to receive(:sleep).with(15).ordered
      expect_replay("B/89000A08")

      described_class.wait_for_primary_checkpoint_replayed(conninfo, Time.now + 60)
    end

    it "gives up once the replay wait runs out" do
      expect_primary(checkpoint_lsn_sql).and_return("B/89000990\n")
      expect_replay("B/20000000")
      expect(described_class).to receive(:warn).with("Standby did not replay the primary checkpoint in time; backing up from an older restartpoint").ordered

      described_class.wait_for_primary_checkpoint_replayed(conninfo, Time.now - 1)
    end

    it "gives up, with the default deadline, when the primary cannot be reached" do
      expect_primary(checkpoint_lsn_sql).and_raise(CommandFail.new("command failed: psql", "", "connection refused"))
      expect(described_class).to receive(:warn).with("Could not read the primary checkpoint (connection refused); backing up from an older restartpoint").ordered

      described_class.wait_for_primary_checkpoint_replayed(conninfo)
    end
  end

  describe ".wait_for_end_wal_archived" do
    let(:replay_sql) { "SELECT pg_catalog.pg_last_wal_replay_lsn()" }
    let(:walfile_sql) { "SELECT pg_catalog.pg_walfile_name('A/23000040')" }
    let(:archiver_sql) { "SELECT last_archived_wal FROM pg_catalog.pg_stat_archiver" }

    def expect_segment_named
      expect(described_class).to receive(:_run_command).with(*psql, replay_sql).and_return("A/23000040\n").ordered
      expect_primary(walfile_sql).and_return("000000020000000A00000023\n")
    end

    it "is true once the primary's archiver passes the segment holding the standby's replay position" do
      expect_segment_named
      expect_primary(archiver_sql).and_return("000000020000000A00000022\n")
      expect(described_class).to receive(:sleep).with(15).ordered
      expect_primary(archiver_sql).and_return("000000020000000A00000024\n")

      expect(described_class.wait_for_end_wal_archived(conninfo, deadline: Time.now + 60)).to be(true)
    end

    it "is true when the archiver's last segment is that segment itself" do
      expect_segment_named
      expect_primary(archiver_sql).and_return("000000020000000A00000023\n")

      expect(described_class.wait_for_end_wal_archived(conninfo, deadline: Time.now + 60)).to be(true)
    end

    it "keeps waiting past a history file, a partial or no archiving yet" do
      expect_segment_named
      ["00000003.history", "000000020000000A00000024.partial", ""].each do |last|
        expect_primary(archiver_sql).and_return("#{last}\n")
        expect(described_class).to receive(:sleep).with(15).ordered
      end
      expect_primary(archiver_sql).and_return("000000020000000A00000024\n")

      expect(described_class.wait_for_end_wal_archived(conninfo, deadline: Time.now + 60)).to be(true)
    end

    it "is false when the segment is not archived by the deadline" do
      expect_segment_named
      expect_primary(archiver_sql).and_return("000000020000000A00000022\n")

      expect(described_class.wait_for_end_wal_archived(conninfo, deadline: Time.now - 1)).to be(false)
    end

    it "is false when the primary stops answering mid-wait" do
      expect_segment_named
      expect_primary(archiver_sql).and_raise(CommandFail.new("command failed: psql", "", "connection refused"))

      expect(described_class.wait_for_end_wal_archived(conninfo)).to be(false)
    end

    it "is false when the primary cannot name the segment" do
      expect(described_class).to receive(:_run_command).with(*psql, replay_sql).and_return("A/23000040\n").ordered
      expect_primary(walfile_sql).and_raise(CommandFail.new("command failed: psql", "", "connection refused"))

      expect(described_class.wait_for_end_wal_archived(conninfo)).to be(false)
    end
  end

  it ".cleanup_on_failure fails without deleting anything when this host pushed no backup" do
    expect(Socket).to receive(:gethostname).and_return("pg-host")
    expect_walg("backup-list --detail --json", [other_host_backup].to_json)
    expect { described_class.cleanup_on_failure }.to raise_error(RuntimeError, "No backup by pg-host found")
  end
end
