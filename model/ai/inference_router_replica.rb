# frozen_string_literal: true

require_relative "../../model"

class InferenceRouterReplica < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :vm, key: :id, primary_key: :vm_id
  many_to_one :inference_router
  one_through_one :load_balancer_vm_port, left_key: :vm_id, left_primary_key: :vm_id, right_key: :id, right_primary_key: :load_balancer_vm_id, join_table: :load_balancers_vms

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
end

# Table: inference_router_replica
# Columns:
#  id                  | uuid                     | PRIMARY KEY
#  created_at          | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  inference_router_id | uuid                     | NOT NULL
#  vm_id               | uuid                     | NOT NULL
# Indexes:
#  inference_router_replica_pkey      | PRIMARY KEY btree (id)
#  inference_router_replica_vm_id_key | UNIQUE btree (vm_id)
# Foreign key constraints:
#  inference_router_replica_inference_router_id_fkey | (inference_router_id) REFERENCES inference_router(id)
#  inference_router_replica_vm_id_fkey               | (vm_id) REFERENCES vm(id)
