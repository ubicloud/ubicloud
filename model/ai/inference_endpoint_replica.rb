# frozen_string_literal: true

require_relative "../../model"

class InferenceEndpointReplica < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :vm, key: :id, primary_key: :vm_id
  many_to_one :inference_endpoint
  one_through_one :load_balancer_vm_port, left_key: :vm_id, left_primary_key: :vm_id, right_key: :id, right_primary_key: :load_balancer_vm_id, join_table: :load_balancers_vms

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy
end

# Table: inference_endpoint_replica
# Columns:
#  id                    | uuid                     | PRIMARY KEY
#  created_at            | timestamp with time zone | NOT NULL DEFAULT now()
#  inference_endpoint_id | uuid                     | NOT NULL
#  vm_id                 | uuid                     | NOT NULL
#  external_state        | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
# Indexes:
#  inference_endpoint_replica_pkey      | PRIMARY KEY btree (id)
#  inference_endpoint_replica_vm_id_key | UNIQUE btree (vm_id)
# Foreign key constraints:
#  inference_endpoint_replica_inference_endpoint_id_fkey | (inference_endpoint_id) REFERENCES inference_endpoint(id)
#  inference_endpoint_replica_vm_id_fkey                 | (vm_id) REFERENCES vm(id)
