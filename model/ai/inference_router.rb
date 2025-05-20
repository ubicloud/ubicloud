# frozen_string_literal: true

require_relative "../../model"

class InferenceRouter < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  one_to_many :replicas, class: :InferenceRouterReplica, key: :inference_router_id
  many_to_one :load_balancer
  many_to_one :private_subnet
  many_to_one :location

  plugin ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :maintenance
end

# Table: inference_router
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  name              | text                     | NOT NULL
#  vm_size           | text                     | NOT NULL
#  replica_count     | integer                  | NOT NULL
#  project_id        | uuid                     | NOT NULL
#  location_id       | uuid                     | NOT NULL
#  load_balancer_id  | uuid                     | NOT NULL
#  private_subnet_id | uuid                     | NOT NULL
# Indexes:
#  inference_router_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  inference_router_load_balancer_id_fkey  | (load_balancer_id) REFERENCES load_balancer(id)
#  inference_router_location_id_fkey       | (location_id) REFERENCES location(id)
#  inference_router_private_subnet_id_fkey | (private_subnet_id) REFERENCES private_subnet(id)
#  inference_router_project_id_fkey        | (project_id) REFERENCES project(id)
# Referenced By:
#  inference_router_replica | inference_router_replica_inference_router_id_fkey | (inference_router_id) REFERENCES inference_router(id)
#  inference_router_target  | inference_router_target_inference_router_id_fkey  | (inference_router_id) REFERENCES inference_router(id)
