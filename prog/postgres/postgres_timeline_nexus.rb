# frozen_string_literal: true

require "forwardable"

class Prog::Postgres::PostgresTimelineNexus < Prog::Base
  subject_is :postgres_timeline

  extend Forwardable
  def_delegators :postgres_timeline, :blob_storage_client

  def self.assemble(location_id:, parent_id: nil)
    if parent_id && (PostgresTimeline[parent_id]).nil?
      fail "No existing parent"
    end

    unless (location = Location[location_id])
      fail "No existing location"
    end

    DB.transaction do
      postgres_timeline = PostgresTimeline.create_with_id(
        parent_id: parent_id,
        access_key: SecureRandom.hex(16),
        secret_key: SecureRandom.hex(32),
        blob_storage_id: MinioCluster.first(project_id: Config.postgres_service_project_id, location_id: location.id)&.id
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
    setup_blob_storage if postgres_timeline.blob_storage
    hop_wait_leader
  end

  label def wait_leader
    hop_destroy if postgres_timeline.leader.nil?

    nap 5 if postgres_timeline.leader.strand.label != "wait"
    hop_wait
  end

  label def wait
    nap 20 * 60 if postgres_timeline.blob_storage.nil?

    # For the purpose of missing backup pages, we act like the very first backup
    # is taken at the creation, which ensures that we would get a page if and only
    # if no backup is taken for 2 days.
    latest_backup_completed_at = postgres_timeline.backups.map(&:last_modified).max || postgres_timeline.created_at
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
      postgres_timeline.leader.vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/take-backup #{postgres_timeline.leader.resource.version}' take_postgres_backup")
      postgres_timeline.latest_backup_started_at = Time.now
      postgres_timeline.save_changes
    end

    hop_wait
  end

  label def destroy
    decr_destroy
    destroy_blob_storage if postgres_timeline.blob_storage
    postgres_timeline.destroy
    pop "postgres timeline is deleted"
  end

  def destroy_blob_storage
    admin_client = Minio::Client.new(
      endpoint: postgres_timeline.blob_storage_endpoint,
      access_key: postgres_timeline.blob_storage.admin_user,
      secret_key: postgres_timeline.blob_storage.admin_password,
      ssl_ca_file_data: postgres_timeline.blob_storage.root_certs
    )

    admin_client.admin_remove_user(postgres_timeline.access_key)
    admin_client.admin_policy_remove(postgres_timeline.ubid)
  end

  def setup_blob_storage
    DB.transaction do
      admin_client = Minio::Client.new(
        endpoint: postgres_timeline.blob_storage_endpoint,
        access_key: postgres_timeline.blob_storage.admin_user,
        secret_key: postgres_timeline.blob_storage.admin_password,
        ssl_ca_file_data: postgres_timeline.blob_storage.root_certs
      )

      # Setup user keys and policy for the timeline
      admin_client.admin_add_user(postgres_timeline.access_key, postgres_timeline.secret_key)
      admin_client.admin_policy_add(postgres_timeline.ubid, postgres_timeline.blob_storage_policy)
      admin_client.admin_policy_set(postgres_timeline.ubid, postgres_timeline.access_key)

      # Create bucket for the timeline
      blob_storage_client.create_bucket(postgres_timeline.ubid)
      blob_storage_client.set_lifecycle_policy(postgres_timeline.ubid, postgres_timeline.ubid, 8)
    end
  end
end
