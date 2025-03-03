# frozen_string_literal: true

require_relative "../model"

class Location < Sequel::Model
  include ResourceMethods

  HETZNER_FSN1_ID = "caa7a807-36c5-8420-a75c-f906839dad71"
  HETZNER_HEL1_ID = "1f214853-0bc4-8020-b910-dffb867ef44f"
  GITHUB_RUNNERS_ID = "6b9ef786-b842-8420-8c65-c25e3d4bdf3d"
  LEASEWEB_WDC02_ID = "e0865080-9a3d-8020-a812-f5817c7afe7f"
end

# Table: location
# Columns:
#  id                         | uuid    | PRIMARY KEY
#  display_name               | text    | NOT NULL
#  name                       | text    | NOT NULL
#  ui_name                    | text    | NOT NULL
#  visible                    | boolean | NOT NULL
#  provider                   | text    | NOT NULL
#  aws_location_credential_id | uuid    |
# Indexes:
#  location_pkey                          | PRIMARY KEY btree (id)
#  aws_location_credential_id_name_unique | UNIQUE btree (name, aws_location_credential_id)
#  aws_location_credential_id_unique      | UNIQUE btree (aws_location_credential_id)
# Check constraints:
#  aws_location_credential_id_provider_check | ((aws_location_credential_id IS NOT NULL) = (provider = 'aws'::text))
# Foreign key constraints:
#  location_aws_location_credential_id_fkey | (aws_location_credential_id) REFERENCES aws_location_credential(id)
#  location_provider_fkey                   | (provider) REFERENCES provider(name)
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
