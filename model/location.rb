# frozen_string_literal: true

require_relative "../model"

class Location < Sequel::Model
  include ResourceMethods
  dataset_module Pagination

  one_to_one :location_credential, key: :id
  many_to_one :project

  plugin :association_dependencies, location_credential: :destroy

  HETZNER_FSN1_ID = "caa7a807-36c5-8420-a75c-f906839dad71"
  HETZNER_HEL1_ID = "1f214853-0bc4-8020-b910-dffb867ef44f"
  GITHUB_RUNNERS_ID = "6b9ef786-b842-8420-8c65-c25e3d4bdf3d"
  LEASEWEB_WDC02_ID = "e0865080-9a3d-8020-a812-f5817c7afe7f"

  dataset_module do
    def for_project(project_id)
      where(Sequel[project_id:] | {project_id: nil})
    end

    def visible_or_for_project(project_id)
      where(Sequel[project_id:] | {project_id: nil, visible: true})
    end
  end

  def visible_or_for_project?(proj_id)
    (visible && project_id.nil?) || project_id == proj_id
  end

  def path
    "/private-location/#{ui_name}"
  end

  # Private Locations only support Postgres resources for now
  def has_resources
    !project.postgres_resources_dataset.where(location_id: id).empty?
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
# Indexes:
#  location_pkey                         | PRIMARY KEY btree (id)
#  location_project_id_display_name_uidx | UNIQUE btree (project_id, display_name)
#  location_project_id_ui_name_uidx      | UNIQUE btree (project_id, ui_name)
# Foreign key constraints:
#  location_project_id_fkey | (project_id) REFERENCES project(id)
#  location_provider_fkey   | (provider) REFERENCES provider(name)
# Referenced By:
#  firewall            | firewall_location_id_fkey           | (location_id) REFERENCES location(id)
#  inference_endpoint  | inference_endpoint_location_id_fkey | (location_id) REFERENCES location(id)
#  inference_router    | inference_router_location_id_fkey   | (location_id) REFERENCES location(id)
#  kubernetes_cluster  | kubernetes_cluster_location_id_fkey | (location_id) REFERENCES location(id)
#  location_credential | location_credential_id_fkey         | (id) REFERENCES location(id)
#  minio_cluster       | minio_cluster_location_id_fkey      | (location_id) REFERENCES location(id)
#  postgres_resource   | postgres_resource_location_id_fkey  | (location_id) REFERENCES location(id)
#  private_subnet      | private_subnet_location_id_fkey     | (location_id) REFERENCES location(id)
#  vm                  | vm_location_id_fkey                 | (location_id) REFERENCES location(id)
#  vm_host             | vm_host_location_id_fkey            | (location_id) REFERENCES location(id)
#  vm_pool             | vm_pool_location_id_fkey            | (location_id) REFERENCES location(id)
