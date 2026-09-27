# frozen_string_literal: true

require_relative "../../model"

# One gateway VM.
class PostgresGatewayReplica < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :postgres_gateway
  many_to_one :vm

  plugin ResourceMethods, encrypted_columns: :tunnel_keys
  plugin SemaphoreMethods, :destroy, :drain, :reconfigure

  def running?
    state == "running"
  end
end

# Table: postgres_gateway_replica
# Columns:
#  id                  | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(531)
#  created_at          | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  postgres_gateway_id | uuid                     | NOT NULL
#  vm_id               | uuid                     | NOT NULL
#  state               | text                     | NOT NULL DEFAULT 'creating'::text
#  tunnel_keys         | text                     |
#  tunnel_rekeyed_at   | timestamp with time zone |
#  tunnel_pushed_at    | timestamp with time zone |
# Indexes:
#  postgres_gateway_replica_pkey        | PRIMARY KEY btree (id)
#  postgres_gateway_replica_gateway_idx | btree (postgres_gateway_id)
# Check constraints:
#  postgres_gateway_replica_state_check | (state = ANY (ARRAY['creating'::text, 'running'::text, 'draining'::text]))
# Foreign key constraints:
#  postgres_gateway_replica_postgres_gateway_id_fkey | (postgres_gateway_id) REFERENCES postgres_gateway(id)
#  postgres_gateway_replica_vm_id_fkey               | (vm_id) REFERENCES vm(id)
