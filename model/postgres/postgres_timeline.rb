# frozen_string_literal: true

require_relative "../../model"

class PostgresTimeline < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :parent, key: :parent_id, class: self
  one_to_one :leader, class: PostgresServer, key: :timeline_id, conditions: {timeline_access: "push"}

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :secret_key
  end

  def bucket_name
    ubid
  end

  def generate_walg_config
    <<-WALG_CONF
WALG_S3_PREFIX=s3://#{ubid}
AWS_ENDPOINT=#{blob_storage_endpoint}
AWS_ACCESS_KEY_ID=#{access_key}
AWS_SECRET_ACCESS_KEY=#{secret_key}
AWS_REGION: us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
    WALG_CONF
  end

  def need_backup?
    return false if blob_storage.nil?
    return false if leader.nil?

    status = leader.vm.sshable.cmd("common/bin/daemonizer --check take_postgres_backup")
    return true if ["Failed", "NotStarted"].include?(status)
    return true if status == "Succeeded" && (latest_backup_started_at.nil? || latest_backup_started_at < Time.now - 60 * 60 * 24)

    false
  end

  def backups
    return [] if blob_storage.nil?

    begin
      blob_storage_client
        .list_objects(ubid, "basebackups_005/")
        .select { _1.key.end_with?("backup_stop_sentinel.json") }
    rescue RuntimeError => ex
      recoverable_errors = ["The Access Key Id you provided does not exist in our records.", "AccessDenied"]
      return [] if recoverable_errors.any? { ex.message.include?(_1) }
      raise
    end
  end

  def latest_backup_label_before_target(target:)
    backup = backups.sort_by(&:last_modified).reverse.find { _1.last_modified < target }
    fail "BUG: no backup found" unless backup
    backup.key.delete_prefix("basebackups_005/").delete_suffix("_backup_stop_sentinel.json")
  end

  def refresh_earliest_backup_completion_time
    update(earliest_backup_completed_at: backups.map(&:last_modified).min)
    earliest_backup_completed_at
  end

  # The "earliest_backup_completed_at" column is used to cache the value,
  # eliminating the need to query the blob storage every time. The
  # "earliest_backup_completed_at" value can be changed when a new backup is
  # created or an existing backup is deleted. It's nil when the server is
  # created, so we get it from the blob storage until the first backup
  # completed. Currently, we lack a backup cleanup feature. Once it is
  # implemented, we can invoke the "refresh_earliest_backup_completion_time"
  # method at the appropriate points.
  def earliest_restore_time
    if (earliest_backup = earliest_backup_completed_at || refresh_earliest_backup_completion_time)
      earliest_backup + 5 * 60
    end
  end

  def latest_restore_time
    Time.now
  end

  def blob_storage
    @blob_storage ||= MinioCluster[blob_storage_id]
  end

  def blob_storage_endpoint
    @blob_storage_endpoint ||= blob_storage.url || blob_storage.ip4_urls.sample
  end

  def blob_storage_client
    @blob_storage_client ||= Minio::Client.new(
      endpoint: blob_storage_endpoint,
      access_key: access_key,
      secret_key: secret_key,
      ssl_ca_file_data: blob_storage.root_certs
    )
  end

  def blob_storage_policy
    {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::#{ubid}*"]}]}
  end
end
