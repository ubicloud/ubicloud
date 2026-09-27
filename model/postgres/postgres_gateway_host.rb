# frozen_string_literal: true

require_relative "../../model"

# The host end of a gateway's IPsec mesh: an ember host the gateway peers with,
# and the keys that end uses. A host is ready for embers the gateway serves
# once its end has been pushed.
class PostgresGatewayHost < Sequel::Model
  many_to_one :vm_host, key: :id
  many_to_one :postgres_gateway

  plugin ResourceMethods, referencing: UBID::TYPE_VM_HOST, encrypted_columns: :tunnel_keys

  dataset_module do
    def ready = exclude(tunnel_pushed_at: nil)
  end
end

# Table: postgres_gateway_host
# Columns:
#  id                  | uuid                     | PRIMARY KEY
#  postgres_gateway_id | uuid                     | NOT NULL
#  tunnel_keys         | text                     |
#  tunnel_rekeyed_at   | timestamp with time zone |
#  tunnel_pushed_at    | timestamp with time zone |
# Indexes:
#  postgres_gateway_host_pkey        | PRIMARY KEY btree (id)
#  postgres_gateway_host_gateway_idx | btree (postgres_gateway_id)
# Foreign key constraints:
#  postgres_gateway_host_id_fkey                  | (id) REFERENCES vm_host(id) ON DELETE CASCADE
#  postgres_gateway_host_postgres_gateway_id_fkey | (postgres_gateway_id) REFERENCES postgres_gateway(id) ON DELETE CASCADE
