# frozen_string_literal: true

require_relative "../../model"

class PostgresTimeline < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :parent, key: :parent_id, class: self
  one_to_one :leader, class: :PostgresServer, key: :timeline_id, conditions: {timeline_access: "push"}

  plugin ResourceMethods
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
        .select { it.key.end_with?("backup_stop_sentinel.json") }
    rescue => ex
      recoverable_errors = ["The Access Key Id you provided does not exist in our records.", "AccessDenied", "No route to host", "Connection refused"]
      Clog.emit("Backup fetch exception") { Util.exception_to_hash(ex) }
      return [] if recoverable_errors.any? { ex.message.include?(it) }
      raise
    end
  end

  def latest_backup_label_before_target(target:)
    backup = backups.sort_by(&:last_modified).reverse.find { it.last_modified < target }
    fail "BUG: no backup found" unless backup
    backup.key.delete_prefix("basebackups_005/").delete_suffix("_backup_stop_sentinel.json")
  end

  # This method is called from serializer and needs to access our blob storage
  # to calculate the answer, so it is inherently slow. It would be good if we
  # can cache this somehow.
  def earliest_restore_time
    if (earliest_backup = backups.map(&:last_modified).min)
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

# Table: postgres_timeline
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  created_at                | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at                | timestamp with time zone | NOT NULL DEFAULT now()
#  parent_id                 | uuid                     |
#  access_key                | text                     |
#  secret_key                | text                     |
#  latest_backup_started_at  | timestamp with time zone |
#  blob_storage_id           | uuid                     |
#  cached_earliest_backup_at | timestamp with time zone |
# Indexes:
#  postgres_timeline_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  postgres_server | postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
