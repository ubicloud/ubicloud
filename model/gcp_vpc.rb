# frozen_string_literal: true

require_relative "../model"

class GcpVpc < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :location, read_only: true
  many_to_many :private_subnets, join_table: :private_subnet_gcp_vpc, remover: nil, clearer: nil

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
end

# Table: gcp_vpc
# Columns:
#  id                   | uuid | PRIMARY KEY DEFAULT gen_random_ubid_uuid(539)
#  project_id           | uuid | NOT NULL
#  location_id          | uuid | NOT NULL
#  name                 | text | NOT NULL
#  firewall_policy_name | text |
#  network_self_link    | text |
# Indexes:
#  gcp_vpc_pkey                       | PRIMARY KEY btree (id)
#  gcp_vpc_project_id_location_id_key | UNIQUE btree (project_id, location_id)
# Foreign key constraints:
#  gcp_vpc_location_id_fkey | (location_id) REFERENCES location(id)
#  gcp_vpc_project_id_fkey  | (project_id) REFERENCES project(id)
# Referenced By:
#  private_subnet_gcp_vpc | private_subnet_gcp_vpc_gcp_vpc_id_fkey | (gcp_vpc_id) REFERENCES gcp_vpc(id)
