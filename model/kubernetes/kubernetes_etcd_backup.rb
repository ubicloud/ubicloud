# frozen_string_literal: true

require_relative "../../model"

class KubernetesEtcdBackup < Sequel::Model
  many_to_one :kubernetes_cluster

  plugin ResourceMethods, encrypted_columns: :secret_key
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
