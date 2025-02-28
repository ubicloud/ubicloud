# frozen_string_literal: true

require_relative "../model"

class Location < Sequel::Model
  include ResourceMethods
end

# Table: location
# Columns:
#  id           | uuid    | PRIMARY KEY
#  display_name | text    | NOT NULL
#  name         | text    | NOT NULL
#  ui_name      | text    | NOT NULL
#  visible      | boolean | NOT NULL
#  provider     | text    | NOT NULL
# Indexes:
#  location_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  location_provider_fkey | (provider) REFERENCES provider(name)
# Referenced By:
#  firewall           | firewall_location_id_fkey           | (location_id) REFERENCES location(id)
#  inference_endpoint | inference_endpoint_location_id_fkey | (location_id) REFERENCES location(id)
#  kubernetes_cluster | kubernetes_cluster_location_id_fkey | (location_id) REFERENCES location(id)
#  minio_cluster      | minio_cluster_location_id_fkey      | (location_id) REFERENCES location(id)
#  postgres_resource  | postgres_resource_location_id_fkey  | (location_id) REFERENCES location(id)
#  private_subnet     | private_subnet_location_id_fkey     | (location_id) REFERENCES location(id)
#  vm                 | vm_location_id_fkey                 | (location_id) REFERENCES location(id)
#  vm_host            | vm_host_location_id_fkey            | (location_id) REFERENCES location(id)
#  vm_pool            | vm_pool_location_id_fkey            | (location_id) REFERENCES location(id)
