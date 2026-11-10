# frozen_string_literal: true

require "json"
require "socket"
require_relative "../../common/lib/util"

class StandbyBackup
  WALG_CONFIG = "/etc/postgresql/wal-g.env"
  ARCHIVE_WAIT_SECONDS = 30 * 60
  REPLAY_WAIT_SECONDS = 10 * 60
  POLL_SECONDS = 15

  # Checkpoint the primary once more WAL than this follows its last checkpoint.
  CHECKPOINT_LAG_BYTES = 1024 * 1024 * 1024

  def self.run(version, cpu_weight = nil)
    fail "Not in recovery; a primary backs up with take-backup" unless standby?

    primary_conninfo = psql("SELECT setting FROM pg_catalog.pg_settings WHERE name = 'primary_conninfo'").strip
    checkpoint_primary_if_needed(primary_conninfo)
    wait_for_primary_checkpoint_replayed(primary_conninfo)

    psql("CHECKPOINT")

    cmd = ["sudo", "-u", "postgres", "wal-g", "backup-push", "/dat/#{version}/data", "--config", WALG_CONFIG, "--verify"]
    if cpu_weight.to_s.match?(/\A\d+\z/) && cpu_weight.to_i.positive?
      cmd.unshift("systemd-run", "--scope", "--collect", "-p", "CPUWeight=#{cpu_weight}")
    end
    r(*cmd)

    fail "#{cleanup_on_failure} deleted: its end WAL segment was not confirmed archived" unless wait_for_end_wal_archived(primary_conninfo)
  end

  def self.checkpoint_primary_if_needed(conninfo)
    lag = Integer(primary_psql(conninfo, "SELECT pg_catalog.pg_wal_lsn_diff(pg_catalog.pg_current_wal_lsn(), redo_lsn)::bigint FROM pg_catalog.pg_control_checkpoint()").strip, 10)
    return if lag < CHECKPOINT_LAG_BYTES

    primary_psql(conninfo, "CHECKPOINT")
  rescue CommandFail => ex
    warn "Could not checkpoint the primary (#{ex.stderr.strip}); waiting on its last checkpoint"
  end

  def self.wait_for_primary_checkpoint_replayed(conninfo, deadline = Time.now + REPLAY_WAIT_SECONDS)
    checkpoint_lsn = parse_lsn(primary_psql(conninfo, "SELECT checkpoint_lsn FROM pg_catalog.pg_control_checkpoint()").strip)

    until parse_lsn(psql("SELECT pg_catalog.pg_last_wal_replay_lsn()").strip) > checkpoint_lsn
      if Time.now >= deadline
        warn "Standby did not replay the primary checkpoint in time; backing up from an older restartpoint"
        return
      end
      sleep POLL_SECONDS
    end
  rescue CommandFail => ex
    warn "Could not read the primary checkpoint (#{ex.stderr.strip}); backing up from an older restartpoint"
  end

  # Poll primary until it confirms the backup's end WAL segment is archived; false on a timeout or failure.
  def self.wait_for_end_wal_archived(conninfo, deadline: Time.now + ARCHIVE_WAIT_SECONDS)
    replay_lsn = parse_lsn(psql("SELECT pg_catalog.pg_last_wal_replay_lsn()").strip)
    segment = primary_psql(conninfo, format("SELECT pg_catalog.pg_walfile_name('%X/%X')", replay_lsn >> 32, replay_lsn & 0xFFFFFFFF)).strip
    sleep POLL_SECONDS until (done = segment_archived?(conninfo, segment)) || Time.now >= deadline
    done
  rescue CommandFail
    false
  end

  # backup-push reports its backup's name only in its log, so find it among the
  # bucket's backups, which include the primary's and other standbys'.
  def self.cleanup_on_failure
    walg = ["sudo", "-u", "postgres", "wal-g"]
    hostname = Socket.gethostname
    latest_owned_backup = JSON.parse(r(*walg, "backup-list", "--detail", "--json", "--config", WALG_CONFIG))
      .select { |backup| backup["hostname"] == hostname }
      .max_by { |backup| parse_lsn(backup.fetch("finish_lsn")) } || fail("No backup by #{hostname} found")
    latest_owned_backup_name = latest_owned_backup.fetch("backup_name")
    r(*walg, "delete", "target", latest_owned_backup_name, "--confirm", "--config", WALG_CONFIG)
    latest_owned_backup_name
  end

  def self.segment_archived?(conninfo, segment)
    last = primary_psql(conninfo, "SELECT last_archived_wal FROM pg_catalog.pg_stat_archiver").strip
    last.match?(/\A[0-9A-F]{24}\z/) && last >= segment
  end

  def self.standby?
    psql("SELECT pg_catalog.pg_is_in_recovery()").strip == "t"
  end

  def self.parse_lsn(lsn)
    return lsn if lsn.is_a?(Integer)

    high, low = lsn.split("/")
    (Integer(high, 16) << 32) | Integer(low, 16)
  end

  def self.primary_psql(conninfo, sql)
    r("sudo", "-u", "postgres", "psql", "-XAt", "-d", conninfo, "-c", sql)
  end

  def self.psql(sql)
    r("sudo", "-u", "postgres", "psql", "-XAt", "-c", sql)
  end
end
