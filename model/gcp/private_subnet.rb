# frozen_string_literal: true

class PrivateSubnet < Sequel::Model
  module Gcp
    private

    def gcp_connect_subnet(subnet)
      raise "Connected subnets are not supported for GCP"
    end

    def gcp_disconnect_subnet(subnet)
      raise "Connected subnets are not supported for GCP"
    end
  end
end

# Table: private_subnet
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  net6              | cidr                     | NOT NULL
#  net4              | cidr                     | NOT NULL
#  state             | text                     | NOT NULL DEFAULT 'creating'::text
#  name              | text                     | NOT NULL
#  last_rekey_at     | timestamp with time zone | NOT NULL DEFAULT now()
#  project_id        | uuid                     | NOT NULL
#  location_id       | uuid                     | NOT NULL
#  firewall_priority | integer                  |
# Indexes:
#  vm_private_subnet_pkey                                | PRIMARY KEY btree (id)
#  private_subnet_project_id_location_id_name_uidx       | UNIQUE btree (project_id, location_id, name)
#  private_subnet_project_location_firewall_priority_idx | UNIQUE btree (project_id, location_id, firewall_priority) WHERE firewall_priority IS NOT NULL
# Check constraints:
#  private_subnet_firewall_priority_check | (firewall_priority IS NULL OR firewall_priority >= 1000 AND firewall_priority <= 8998 AND (firewall_priority % 2) = 0)
# Foreign key constraints:
#  private_subnet_location_id_fkey | (location_id) REFERENCES location(id)
#  private_subnet_project_id_fkey  | (project_id) REFERENCES project(id)
# Referenced By:
#  connected_subnet            | connected_subnet_subnet_id_1_fkey                | (subnet_id_1) REFERENCES private_subnet(id)
#  connected_subnet            | connected_subnet_subnet_id_2_fkey                | (subnet_id_2) REFERENCES private_subnet(id)
#  firewalls_private_subnets   | firewalls_private_subnets_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  inference_endpoint          | inference_endpoint_private_subnet_id_fkey        | (private_subnet_id) REFERENCES private_subnet(id)
#  inference_router            | inference_router_private_subnet_id_fkey          | (private_subnet_id) REFERENCES private_subnet(id)
#  kubernetes_cluster          | kubernetes_cluster_private_subnet_id_fkey        | (private_subnet_id) REFERENCES private_subnet(id)
#  load_balancer               | load_balancer_private_subnet_id_fkey             | (private_subnet_id) REFERENCES private_subnet(id)
#  minio_cluster               | minio_cluster_private_subnet_id_fkey             | (private_subnet_id) REFERENCES private_subnet(id)
#  nic                         | nic_private_subnet_id_fkey                       | (private_subnet_id) REFERENCES private_subnet(id)
#  postgres_resource           | postgres_resource_private_subnet_id_fkey         | (private_subnet_id) REFERENCES private_subnet(id)
#  private_subnet_aws_resource | private_subnet_aws_resource_id_fkey              | (id) REFERENCES private_subnet(id)
#  private_subnet_gcp_vpc      | private_subnet_gcp_vpc_private_subnet_id_fkey    | (private_subnet_id) REFERENCES private_subnet(id) ON DELETE CASCADE
#  victoria_metrics_resource   | victoria_metrics_resource_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
