# frozen_string_literal: true

require "forwardable"

class Prog::Postgres::PostgresTimelineNexus < Prog::Base
  subject_is :postgres_timeline

  extend Forwardable
  def_delegators :postgres_timeline, :blob_storage_client

  semaphore :destroy

  def self.assemble(parent_id: nil)
    DB.transaction do
      postgres_timeline = PostgresTimeline.create_with_id(
        parent_id: parent_id,
        access_key: Config.postgres_service_blob_storage_access_key,
        secret_key: Config.postgres_service_blob_storage_secret_key
      )
      Strand.create(prog: "Postgres::PostgresTimelineNexus", label: "start") { _1.id = postgres_timeline.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    blob_storage_client.create_bucket(bucket_name: postgres_timeline.ubid) if postgres_timeline.blob_storage_endpoint
    hop_wait_leader
  end

  label def wait_leader
    nap 5 if postgres_timeline.leader.strand.label != "wait"
    hop_wait
  end

  label def wait
    if postgres_timeline.need_backup?
      hop_take_backup
    end

    nap 20 * 60
  end

  label def take_backup
    # It is possible that we started backup but crashed before saving the state
    # to database. Since backup taking is an expensive operation, we check if
    # backup is truly needed.
    if postgres_timeline.need_backup?
      postgres_timeline.leader.vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/take-backup' take_postgres_backup")
    end

    postgres_timeline.last_backup_started_at = Time.now
    postgres_timeline.save_changes

    hop_wait
  end

  label def destroy
    decr_destroy
    postgres_timeline.destroy
    pop "postgres timeline is deleted"
  end
end
