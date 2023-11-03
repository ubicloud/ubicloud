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
AWS_ENDPOINT=#{blob_storage.connection_strings.first}
AWS_ACCESS_KEY_ID=#{access_key}
AWS_SECRET_ACCESS_KEY=#{secret_key}
AWS_REGION: us-east-1
AWS_S3_FORCE_PATH_STYLE=true
PGHOST=/var/run/postgresql
    WALG_CONF
  end

  def need_backup?
    return false if last_ineffective_check_at && last_ineffective_check_at > Time.now - 60 * 20

    status = leader.vm.sshable.cmd("common/bin/daemonizer --check take_postgres_backup")
    return true if ["Failed", "NotStarted"].include?(status)
    return true if status == "Succeeded" && (last_backup_started_at.nil? || last_backup_started_at < Time.now - 60 * 60 * 24)

    self.last_ineffective_check_at = Time.now
    save_changes
    false
  end

  def backups
    blob_storage_client
      .list_objects(bucket_name: ubid, folder_path: "basebackups_005/")
      .select { _1.key.end_with?("backup_stop_sentinel.json") }
  end

  def last_backup_label_before_target(target:)
    backup = backups.sort_by(&:last_modified).reverse.find { _1.last_modified < target }
    backup.key.delete_prefix("basebackups_005/").delete_suffix("_backup_stop_sentinel.json")
  end

  def blob_storage
    @blob_storage ||= Project[Config.postgres_service_project_id].minio_clusters.first
  end

  def blob_storage_client
    @blob_storage_client ||= MinioClient.new(
      endpoint: blob_storage.connection_strings.first,
      access_key: Config.postgres_service_blob_storage_access_key,
      secret_key: Config.postgres_service_blob_storage_secret_key
    )
  end
end
