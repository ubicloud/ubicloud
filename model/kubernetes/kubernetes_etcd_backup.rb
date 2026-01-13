# frozen_string_literal: true

require_relative "../../model"

class KubernetesEtcdBackup < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :location, read_only: true
  many_to_one :kubernetes_cluster, read_only: true

  plugin ResourceMethods, encrypted_columns: :secret_key
  plugin SemaphoreMethods, :destroy

  BACKUP_BUCKET_EXPIRATION_DAYS = 7

  def need_backup?
    return false unless blob_storage
    return false if kubernetes_cluster.functional_nodes.empty?

    sshable = kubernetes_cluster.sshable
    case sshable.d_check("backup_etcd")
    when "Failed", "NotStarted"
      true
    when "Succeeded"
      latest_backup_started_at.nil? || latest_backup_started_at < Time.now - 60 * 60
    else
      false
    end
  end

  def next_backup_time
    return Time.now + 86400 unless blob_storage
    return Time.now unless latest_backup_started_at

    latest_backup_started_at + 60 * 60
  end

  def blob_storage
    return @blob_storage if defined?(@blob_storage)
    @blob_storage = MinioCluster[project_id: Config.minio_service_project_id, location_id: location.id]
  end

  def blob_storage_policy
    {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::#{ubid}*"]}]}
  end

  def blob_storage_endpoint
    @blob_storage_endpoint ||= blob_storage.url || blob_storage.ip4_urls.sample
  end

  def blob_storage_client
    @blob_storage_client ||= Minio::Client.new(
      endpoint: blob_storage_endpoint,
      access_key:,
      secret_key:,
      ssl_ca_data: blob_storage.root_certs
    )
  end

  def setup_bucket
    blob_storage_client.create_bucket(ubid)
    blob_storage_client.set_lifecycle_policy(ubid, ubid, BACKUP_BUCKET_EXPIRATION_DAYS)
  end
end

# Table: kubernetes_etcd_backup
# Columns:
#  id                       | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(619)
#  access_key               | text                     | NOT NULL
#  secret_key               | text                     | NOT NULL
#  latest_backup_started_at | timestamp with time zone |
#  location_id              | uuid                     | NOT NULL
#  kubernetes_cluster_id    | uuid                     | NOT NULL
# Indexes:
#  kubernetes_etcd_backup_pkey                        | PRIMARY KEY btree (id)
#  kubernetes_etcd_backup_kubernetes_cluster_id_index | btree (kubernetes_cluster_id)
#  kubernetes_etcd_backup_location_id_index           | btree (location_id)
# Foreign key constraints:
#  kubernetes_etcd_backup_kubernetes_cluster_id_fkey | (kubernetes_cluster_id) REFERENCES kubernetes_cluster(id)
#  kubernetes_etcd_backup_location_id_fkey           | (location_id) REFERENCES location(id)
