# frozen_string_literal: true

class Location < Sequel::Model
  one_to_many :location_gcp_azs, remover: nil, clearer: nil

  module Gcp
    def pg_gce_image(pg_version, arch)
      image = PgGceImage.find(pg_version:, arch:)
      raise "No GCE image found for PostgreSQL #{pg_version} (#{arch})" unless image
      "projects/#{image.gcp_project_id}/global/images/#{image.gce_image_name}"
    end

    private

    def gcp_pg_boot_image(pg_version, arch, flavor)
      pg_gce_image(pg_version, arch)
    end

    def gcp_azs
      v = location_gcp_azs_dataset.all
      return v unless v.empty?
      set_gcp_azs
    end

    def set_gcp_azs
      region = name.delete_prefix("gcp-")
      get_gcp_zones(region).map do |zone|
        az = zone.name.delete_prefix("#{region}-")
        LocationGcpAz.create(location_id: id, az:, zone_name: zone.name)
      end
    end

    def get_gcp_zones(region)
      credential = location_credential
      zones = credential.zones_client.list(project: credential.project_id).to_a
      zones.select { it.name.start_with?("#{region}-") && it.status == "UP" }
    end
  end
end

# Table: location
# Columns:
#  id           | uuid    | PRIMARY KEY
#  display_name | text    | NOT NULL
#  name         | text    | NOT NULL
#  ui_name      | text    | NOT NULL
#  visible      | boolean | NOT NULL
#  provider     | text    | NOT NULL
#  project_id   | uuid    |
#  dns_suffix   | text    |
#  byoc         | boolean | NOT NULL DEFAULT false
# Indexes:
#  location_pkey                         | PRIMARY KEY btree (id)
#  location_project_id_display_name_uidx | UNIQUE btree (project_id, display_name)
#  location_project_id_ui_name_uidx      | UNIQUE btree (project_id, ui_name)
# Foreign key constraints:
#  location_project_id_fkey | (project_id) REFERENCES project(id)
#  location_provider_fkey   | (provider) REFERENCES provider(name)
# Referenced By:
#  firewall                  | firewall_location_id_fkey                  | (location_id) REFERENCES location(id)
#  inference_endpoint        | inference_endpoint_location_id_fkey        | (location_id) REFERENCES location(id)
#  inference_router          | inference_router_location_id_fkey          | (location_id) REFERENCES location(id)
#  kubernetes_cluster        | kubernetes_cluster_location_id_fkey        | (location_id) REFERENCES location(id)
#  kubernetes_etcd_backup    | kubernetes_etcd_backup_location_id_fkey    | (location_id) REFERENCES location(id)
#  location_aws_az           | location_aws_az_location_id_fkey           | (location_id) REFERENCES location(id) ON DELETE CASCADE
#  location_credential       | location_credential_id_fkey                | (id) REFERENCES location(id)
#  location_gcp_az           | location_gcp_az_location_id_fkey           | (location_id) REFERENCES location(id) ON DELETE CASCADE
#  minio_cluster             | minio_cluster_location_id_fkey             | (location_id) REFERENCES location(id)
#  postgres_resource         | postgres_resource_location_id_fkey         | (location_id) REFERENCES location(id)
#  postgres_timeline         | postgres_timeline_location_id_fkey         | (location_id) REFERENCES location(id)
#  private_subnet            | private_subnet_location_id_fkey            | (location_id) REFERENCES location(id)
#  victoria_metrics_resource | victoria_metrics_resource_location_id_fkey | (location_id) REFERENCES location(id)
#  vm                        | vm_location_id_fkey                        | (location_id) REFERENCES location(id)
#  vm_host                   | vm_host_location_id_fkey                   | (location_id) REFERENCES location(id)
#  vm_pool                   | vm_pool_location_id_fkey                   | (location_id) REFERENCES location(id)
