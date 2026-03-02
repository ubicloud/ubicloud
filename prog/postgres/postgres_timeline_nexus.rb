# frozen_string_literal: true

class Prog::Postgres::PostgresTimelineNexus < Prog::Base
  subject_is :postgres_timeline

  def self.assemble(location_id:, parent_id: nil)
    if parent_id && PostgresTimeline[parent_id].nil?
      fail "No existing parent"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    DB.transaction do
      postgres_timeline = PostgresTimeline.create(parent_id:, location_id: location.id)
      if postgres_timeline.generate_blob_storage_credentials?
        postgres_timeline.update(access_key: SecureRandom.hex(16), secret_key: SecureRandom.hex(32))
      end
      Strand.create_with_id(postgres_timeline, prog: "Postgres::PostgresTimelineNexus", label: "start")
    end
  end

  label def start
    if postgres_timeline.blob_storage
      postgres_timeline.setup_blob_storage
      hop_setup_bucket
    end

    hop_wait_leader
  end

  label def setup_bucket
    nap 1 if postgres_timeline.aws? && !Config.aws_postgres_iam_access && !aws_access_key_is_available?

    # Create bucket for the timeline
    postgres_timeline.create_bucket
    postgres_timeline.set_lifecycle_policy
    hop_wait_leader
  end

  label def wait_leader
    nap 5 if postgres_timeline.leader.nil? || postgres_timeline.leader.strand.label != "wait"
    hop_wait
  end

  label def wait
    dependent = PostgresServer[timeline_id: postgres_timeline.id]
    backups = postgres_timeline.backups
    if dependent.nil? && backups.empty? && Time.now - postgres_timeline.created_at > 10 * 24 * 60 * 60
      Clog.emit("Self-destructing timeline as no leader or backups are present and it is older than 10 days", postgres_timeline)
      hop_destroy
    end

    nap 20 * 60 if postgres_timeline.blob_storage.nil?

    # For the purpose of missing backup pages, we act like the very first backup
    # is taken at the creation, which ensures that we would get a page if and only
    # if no backup is taken for 2 days.
    latest_backup_completed_at = backups.map(&:last_modified).max || postgres_timeline.created_at
    if postgres_timeline.leader && latest_backup_completed_at < Time.now - 2 * 24 * 60 * 60 # 2 days
      Prog::PageNexus.assemble("Missing backup at #{postgres_timeline}!", ["MissingBackup", postgres_timeline.id], postgres_timeline.ubid)
    else
      Page.from_tag_parts("MissingBackup", postgres_timeline.id)&.incr_resolve
    end

    if postgres_timeline.need_backup?
      hop_take_backup
    end

    nap 20 * 60
  end

  label def take_backup
    # It is possible that we already started backup but crashed before saving
    # the state to database. Since backup taking is an expensive operation,
    # we check if backup is truly needed.
    if postgres_timeline.need_backup?
      d_command = NetSsh.command("sudo postgres/bin/take-backup :version", version: postgres_timeline.leader.version)
      postgres_timeline.leader.vm.sshable.cmd("common/bin/daemonizer :d_command take_postgres_backup", d_command:)
      postgres_timeline.latest_backup_started_at = Time.now
      postgres_timeline.save_changes
    end

    hop_wait
  end

  label def destroy
    decr_destroy
    postgres_timeline.destroy_blob_storage if postgres_timeline.blob_storage
    postgres_timeline.destroy
    pop "postgres timeline is deleted"
  end

  def aws_access_key_is_available?
    postgres_timeline.location.location_credential.iam_client
      .list_access_keys(user_name: postgres_timeline.ubid)
      .access_key_metadata.any? { it.access_key_id == postgres_timeline.access_key }
  end
end
