# frozen_string_literal: true

require_relative "../../model"

class DockerRegistryMirrorServer < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :vm, key: :id, primary_key: :vm_id

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy
end

# Table: docker_registry_mirror_server
# Columns:
#  id         | uuid                     | PRIMARY KEY DEFAULT gen_random_uuid()
#  created_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  vm_id      | uuid                     | NOT NULL
# Indexes:
#  docker_registry_mirror_server_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  docker_registry_mirror_server_vm_id_fkey | (vm_id) REFERENCES vm(id)
