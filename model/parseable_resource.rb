# frozen_string_literal: true

require_relative "../model"

class ParseableResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location, read_only: true
  one_to_many :servers, class: :ParseableServer, is_used: true, read_only: true
  many_to_one :private_subnet, read_only: true

  plugin ResourceMethods, redacted_columns: [:root_cert_1, :root_cert_2],
    encrypted_columns: [:admin_password, :root_cert_key_1, :root_cert_key_2, :secret_key]
  plugin SemaphoreMethods, :destroy, :reconfigure

  LOG_BUCKET_EXPIRATION_DAYS = 7

  def self.for_project(project_id)
    ParseableResource.where(
      project_id: [project_id, Config.parseable_service_project_id].compact,
    ).order(project_id: Config.parseable_service_project_id).first
  end

  def self.client_for_project(project_id)
    par = for_project(project_id)
    par&.servers&.first&.client
  end

  def hostname
    "#{name}.#{Config.parseable_host_name}"
  end

  def dns_zone
    @dns_zone ||= DnsZone.where(project_id: Config.parseable_service_project_id, name: Config.parseable_host_name).first
  end

  def root_certs
    [root_cert_1, root_cert_2].join("\n") if root_cert_1 && root_cert_2
  end

  alias_method :bucket_name, :ubid

  def blob_storage
    @blob_storage ||= MinioCluster.where(
      project_id: [Config.postgres_service_project_id, Config.minio_service_project_id].compact,
      location_id: location.id,
    ).order(project_id: Config.postgres_service_project_id).last
  end

  def blob_storage_endpoint
    @blob_storage_endpoint ||= blob_storage.url || blob_storage.ip4_urls.sample
  end

  def blob_storage_client
    @blob_storage_client ||= Minio::Client.new(
      endpoint: blob_storage_endpoint,
      access_key: blob_storage_access_key,
      secret_key: blob_storage_secret_key,
      ssl_ca_data: blob_storage.root_certs,
    )
  end

  def blob_storage_admin_client
    @blob_storage_admin_client ||= Minio::Client.new(
      endpoint: blob_storage_endpoint,
      access_key: blob_storage.admin_user,
      secret_key: blob_storage.admin_password,
      ssl_ca_data: blob_storage.root_certs,
    )
  end

  def blob_storage_policy
    {Version: "2012-10-17", Statement: [{Effect: "Allow", Action: ["s3:*"], Resource: ["arn:aws:s3:::#{bucket_name}*"]}]}
  end
end

# Table: parseable_resource
# Columns:
#  id                          | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(705)
#  name                        | text                     | NOT NULL
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  admin_user                  | text                     | NOT NULL
#  admin_password              | text                     | NOT NULL
#  blob_storage_access_key     | text                     | NOT NULL
#  blob_storage_secret_key     | text                     | NOT NULL
#  target_vm_size              | text                     | NOT NULL
#  target_storage_size_gib     | bigint                   | NOT NULL
#  root_cert_1                 | text                     |
#  root_cert_key_1             | text                     |
#  root_cert_2                 | text                     |
#  root_cert_key_2             | text                     |
#  certificate_last_checked_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  project_id                  | uuid                     | NOT NULL
#  location_id                 | uuid                     | NOT NULL
#  private_subnet_id           | uuid                     |
# Indexes:
#  parseable_resource_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  parseable_resource_location_id_fkey       | (location_id) REFERENCES location(id)
#  parseable_resource_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  parseable_resource_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  parseable_server | parseable_server_parseable_resource_id_fkey | (parseable_resource_id) REFERENCES parseable_resource(id)
