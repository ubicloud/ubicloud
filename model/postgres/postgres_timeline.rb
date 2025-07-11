# frozen_string_literal: true

require_relative "../../model"
require "aws-sdk-s3"

class PostgresTimeline < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :parent, key: :parent_id, class: self
  one_to_one :leader, class: :PostgresServer, key: :timeline_id, conditions: {timeline_access: "push"}
  many_to_one :location

  plugin ResourceMethods, encrypted_columns: :secret_key
  plugin SemaphoreMethods, :destroy

  BACKUP_BUCKET_EXPIRATION_DAYS = 8

  def bucket_name
    ubid
  end

  def generate_walg_config
    <<-WALG_CONF
WALG_S3_PREFIX=s3://#{ubid}
AWS_ENDPOINT=#{blob_storage_endpoint}
AWS_ACCESS_KEY_ID=#{access_key}
AWS_SECRET_ACCESS_KEY=#{secret_key}
AWS_REGION: #{aws? ? location.name : "us-east-1"}
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
      list_objects("basebackups_005/")
        .select { it.key.end_with?("backup_stop_sentinel.json") }
    rescue => ex
      recoverable_errors = ["The AWS Access Key Id you provided does not exist in our records.", "The specified bucket does not exist", "AccessDenied", "No route to host", "Connection refused"]
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

  def earliest_restore_time
    # Check if we have cached earliest backup time, if not, calculate it.
    # The cached time is valid if its within BACKUP_BUCKET_EXPIRATION_DAYS.
    time_limit = Time.now - BACKUP_BUCKET_EXPIRATION_DAYS * 24 * 60 * 60

    if cached_earliest_backup_at.nil? || cached_earliest_backup_at <= time_limit
      earliest_backup = backups
        .select { |b| b.last_modified > time_limit }
        .map(&:last_modified).min

      update(cached_earliest_backup_at: earliest_backup)
    end

    if cached_earliest_backup_at
      cached_earliest_backup_at + 5 * 60
    end
  end

  def latest_restore_time
    Time.now
  end

  def aws?
    location&.aws?
  end

  S3BlobStorage = Struct.new(:url)

  def blob_storage
    @blob_storage ||= MinioCluster[blob_storage_id] || (aws? ? S3BlobStorage.new("https://s3.#{location.name}.amazonaws.com") : nil)
  end

  def blob_storage_endpoint
    @blob_storage_endpoint ||= blob_storage.url || blob_storage.ip4_urls.sample
  end

  def blob_storage_client
    @blob_storage_client ||= aws? ? Aws::S3::Client.new(
      region: location.name,
      access_key_id: access_key,
      secret_access_key: secret_key,
      endpoint: blob_storage_endpoint,
      force_path_style: true
    ) : Minio::Client.new(
      endpoint: blob_storage_endpoint,
      access_key: access_key,
      secret_key: secret_key,
      ssl_ca_data: blob_storage.root_certs
    )
  end

  def blob_storage_policy
    {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::#{ubid}*"]}]}
  end

  def list_objects(prefix)
    aws? ?
    aws_list_objects(prefix)
    : blob_storage_client.list_objects(ubid, prefix)
  end

  def aws_list_objects(prefix)
    response = blob_storage_client.list_objects_v2(bucket: ubid, prefix: prefix)
    objects = response.contents
    while response.is_truncated
      response = blob_storage_client.list_objects_v2(bucket: ubid, prefix: prefix, continuation_token: response.next_continuation_token)
      objects.concat(response.contents)
    end
    objects
  end

  def create_bucket
    aws? ?
      blob_storage_client.create_bucket({
        bucket: ubid,
        create_bucket_configuration: {
          location_constraint: location.name
        }
      })
    : blob_storage_client.create_bucket(ubid)
  end

  def set_lifecycle_policy
    aws? ?
      blob_storage_client.put_bucket_lifecycle_configuration({
        bucket: ubid,
        lifecycle_configuration: {
          rules: [
            {
              id: "DeleteOldBackups",
              prefix: "basebackups_005/",
              status: "Enabled",
              expiration: {
                days: BACKUP_BUCKET_EXPIRATION_DAYS
              }
            }
          ]
        }
      })
    : blob_storage_client.set_lifecycle_policy(ubid, ubid, BACKUP_BUCKET_EXPIRATION_DAYS)
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
#  location_id               | uuid                     |
#  cached_earliest_backup_at | timestamp with time zone |
# Indexes:
#  postgres_timeline_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_timeline_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_server | postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
