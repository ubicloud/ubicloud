# frozen_string_literal: true

require_relative "../../model"

# The PostgreSQL entry point for a location's embers: a fleet of proxy VMs
# behind the location's TCP load balancer and a wildcard certificate.
#
# One wildcard DNS record per location points at the load balancer, so no DNS
# changes ever happen per ember.
class PostgresGateway < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :location
  many_to_one :load_balancer
  many_to_one :private_subnet
  one_to_many :replicas, class: :PostgresGatewayReplica
  one_to_many :hosts, class: :PostgresGatewayHost

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :reconfigure

  def hostname_for(ember)
    ember.hostname(hostname_suffix)
  end
end

# Table: postgres_gateway
# Columns:
#  id                | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(540)
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  location_id       | uuid                     | NOT NULL
#  load_balancer_id  | uuid                     |
#  private_subnet_id | uuid                     |
#  hostname_suffix   | text                     | NOT NULL
#  replica_count     | integer                  | NOT NULL DEFAULT 2
# Indexes:
#  postgres_gateway_pkey            | PRIMARY KEY btree (id)
#  postgres_gateway_location_id_key | UNIQUE btree (location_id)
# Foreign key constraints:
#  postgres_gateway_load_balancer_id_fkey  | (load_balancer_id) REFERENCES load_balancer(id)
#  postgres_gateway_location_id_fkey       | (location_id) REFERENCES location(id)
#  postgres_gateway_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
# Referenced By:
#  postgres_gateway_host    | postgres_gateway_host_postgres_gateway_id_fkey    | (postgres_gateway_id) REFERENCES postgres_gateway(id) ON DELETE CASCADE
#  postgres_gateway_replica | postgres_gateway_replica_postgres_gateway_id_fkey | (postgres_gateway_id) REFERENCES postgres_gateway(id)
