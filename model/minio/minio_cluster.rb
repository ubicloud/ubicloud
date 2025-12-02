# frozen_string_literal: true

# {{{ CONFLATION
require_relative "../../model"

class MinioCluster < Sequel::Model
  # ZZZ: Only need for test when in thin aws mode
  # many_to_one :project
  # one_to_many :pools, key: :cluster_id, class: :MinioPool, order: :start_index
  # many_to_many :servers, join_table: :minio_pool, left_key: :cluster_id, right_key: :id, right_primary_key: :minio_pool_id, class: :MinioServer, order: :index
  one_to_one :strand, key: :id
  # many_to_one :private_subnet
  # many_to_one :location, key: :location_id

  plugin ResourceMethods, redacted_columns: [:root_cert_1, :root_cert_2],
    encrypted_columns: [:admin_password, :root_cert_key_1, :root_cert_key_2]
  plugin SemaphoreMethods, :destroy, :reconfigure

  def storage_size_gib
    pools.sum(&:storage_size_gib)
  end

  def server_count
    pools.sum(&:server_count)
  end

  def drive_count
    pools.sum(&:drive_count)
  end

  def ip4_urls
    servers.map(&:ip4_url)
  end

  def single_instance_single_drive?
    server_count == 1 && drive_count == 1
  end

  def single_instance_multi_drive?
    server_count == 1 && drive_count > 1
  end

  def hostname
    "#{name}.#{Config.minio_host_name}"
  end

  def url
    dns_zone ? "https://#{hostname}:9000" : nil
  end

  def dns_zone
    @dns_zone ||= DnsZone.where(project_id: Config.minio_service_project_id, name: Config.minio_host_name).first
  end

  def root_certs
    root_cert_1.to_s + root_cert_2.to_s
  end
end

# Table: minio_cluster
# Columns:
#  id                          | uuid                        | PRIMARY KEY
#  name                        | text                        | NOT NULL
#  created_at                  | timestamp without time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  admin_user                  | text                        | NOT NULL
#  admin_password              | text                        | NOT NULL
#  private_subnet_id           | uuid                        |
#  root_cert_1                 | text                        |
#  root_cert_key_1             | text                        |
#  root_cert_2                 | text                        |
#  root_cert_key_2             | text                        |
#  certificate_last_checked_at | timestamp with time zone    | NOT NULL DEFAULT now()
#  project_id                  | uuid                        | NOT NULL
#  location_id                 | uuid                        | NOT NULL
# Indexes:
#  minio_cluster_pkey                             | PRIMARY KEY btree (id)
#  minio_cluster_project_id_location_id_name_uidx | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  minio_cluster_location_id_fkey       | (location_id) REFERENCES location(id)
#  minio_cluster_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  minio_cluster_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  minio_pool | minio_pool_cluster_id_fkey | (cluster_id) REFERENCES minio_cluster(id)
# }}} CONFLATION
