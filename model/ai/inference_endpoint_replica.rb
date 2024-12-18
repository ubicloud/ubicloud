# frozen_string_literal: true

require_relative "../../model"

class InferenceEndpointReplica < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :vm, key: :id, primary_key: :vm_id
  many_to_one :inference_endpoint
  one_to_one :load_balancers_vm, class: LoadBalancersVms, key: :vm_id, primary_key: :vm_id

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy
end

# Table: inference_endpoint_replica
# Columns:
#  id                    | uuid                     | PRIMARY KEY
#  created_at            | timestamp with time zone | NOT NULL DEFAULT now()
#  inference_endpoint_id | uuid                     | NOT NULL
#  vm_id                 | uuid                     | NOT NULL
# Indexes:
#  inference_endpoint_replica_pkey      | PRIMARY KEY btree (id)
#  inference_endpoint_replica_vm_id_key | UNIQUE btree (vm_id)
# Foreign key constraints:
#  inference_endpoint_replica_inference_endpoint_id_fkey | (inference_endpoint_id) REFERENCES inference_endpoint(id)
#  inference_endpoint_replica_vm_id_fkey                 | (vm_id) REFERENCES vm(id)
