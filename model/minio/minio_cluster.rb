# frozen_string_literal: true

require_relative "../../model"

class MinioCluster < Sequel::Model
  one_to_many :pools, key: :cluster_id, class: :MinioPool do |ds|
    ds.order(:start_index)
  end
  many_through_many :servers, [[:minio_pool, :cluster_id, :id], [:minio_server, :minio_pool_id, :id]], class: :MinioServer do |ds|
    ds.order(:index)
  end
  one_to_one :strand, key: :id
  many_to_one :private_subnet, key: :private_subnet_id

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods

  semaphore :destroy, :reconfigure

  plugin :column_encryption do |enc|
    enc.column :admin_password
    enc.column :root_cert_key_1
    enc.column :root_cert_key_2
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/minio-cluster/#{name}"
  end

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def generate_etc_hosts_entry
    servers.map do |server|
      "#{server.private_ipv4_address} #{server.hostname}"
    end.join("\n")
  end

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

  def self.redacted_columns
    super + [:root_cert_1, :root_cert_2]
  end
end

# Table: minio_cluster
# Columns:
#  id                          | uuid                        | PRIMARY KEY
#  name                        | text                        | NOT NULL
#  location                    | text                        | NOT NULL
#  created_at                  | timestamp without time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  admin_user                  | text                        | NOT NULL
#  admin_password              | text                        | NOT NULL
#  private_subnet_id           | uuid                        |
#  root_cert_1                 | text                        |
#  root_cert_key_1             | text                        |
#  root_cert_2                 | text                        |
#  root_cert_key_2             | text                        |
#  certificate_last_checked_at | timestamp with time zone    | NOT NULL DEFAULT now()
#  project_id                  | uuid                        |
# Indexes:
#  minio_cluster_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  minio_cluster_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
# Referenced By:
#  minio_pool | minio_pool_cluster_id_fkey | (cluster_id) REFERENCES minio_cluster(id)
