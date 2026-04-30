# frozen_string_literal: true

class Prog::Postgres::PostgresTimelineNexus < Prog::Base
  subject_is :postgres_timeline

  def self.assemble(location_id:, parent_id: nil)
    if parent_id && (parent = PostgresTimeline[parent_id]).nil?
      fail "No existing parent"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    DB.transaction do
      postgres_timeline = PostgresTimeline.create(parent_id:, location_id: location.id, backup_period_hours: parent&.backup_period_hours || 24)
      if postgres_timeline.generate_blob_storage_credentials?
        postgres_timeline.update(access_key: SecureRandom.hex(16), secret_key: SecureRandom.hex(32))
      end
      Strand.create_with_id(postgres_timeline, prog: "Postgres::PostgresTimelineNexus", label: "start")
    end
  end

  def before_run
    super

    return if postgres_timeline.created_at > Time.now - 6 * 60 * 60

    latest_backup_completed_at = postgres_timeline.backups.map(&:last_modified).max
    if postgres_timeline.leader && (latest_backup_completed_at.nil? || latest_backup_completed_at < Time.now - 2 * 24 * 60 * 60)
      severity = (latest_backup_completed_at && latest_backup_completed_at < Time.now - 3 * 24 * 60 * 60) ? "error" : "warning"
      Prog::PageNexus.assemble("Missing backup at #{postgres_timeline}!", ["MissingBackup", postgres_timeline.id], postgres_timeline.ubid, severity:)
    else
      Page.from_tag_parts("MissingBackup", postgres_timeline.id)&.incr_resolve
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
    if dependent.nil? && postgres_timeline.backups.empty? && Time.now - postgres_timeline.created_at > 10 * 24 * 60 * 60
      Clog.emit("Self-destructing timeline as no leader or backups are present and it is older than 10 days", postgres_timeline)
      hop_destroy
    end

    hop_take_backup if postgres_timeline.need_backup?

    nap 20 * 60
  end

  label def take_backup
    sshable = postgres_timeline.leader.vm.sshable
    case sshable.d_check("take_postgres_backup")
    when "Succeeded"
      sshable.d_clean("take_postgres_backup")
      decr_take_backup_for_scale_down
      hop_wait
    when "InProgress"
      nap 60
    else # "Failed", "NotStarted"
      size_gib = postgres_timeline.leader.data_disk_usage(raise_on_error: true).fdiv(1024 * 1024).ceil
      sshable.d_run("take_postgres_backup", "sudo", "postgres/bin/take-backup", postgres_timeline.leader.version)
      postgres_timeline.update(latest_backup_started_at: Time.now, latest_backup_size_in_gib: size_gib)
      nap 60
    end
  end

  label def destroy
    decr_destroy
    postgres_timeline.destroy_blob_storage if postgres_timeline.blob_storage
    postgres_timeline.destroy
    pop "postgres timeline is deleted"
  end

  def aws_access_key_is_available?
    iam_client.list_access_keys(user_name: postgres_timeline.ubid).access_key_metadata.any? { it.access_key_id == postgres_timeline.access_key }
  end

  def iam_client
    postgres_timeline.location.location_credential_aws.iam_client
  end
end
