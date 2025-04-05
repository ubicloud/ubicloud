# frozen_string_literal: true

require_relative "../../model"

class DockerRegistryMirror < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :vm, key: :id, primary_key: :vm_id

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy
end

# Table: docker_registry_mirror
# Columns:
#  id                        | uuid                     | PRIMARY KEY
#  created_at                | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  last_certificate_reset_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  vm_id                     | uuid                     | NOT NULL
# Indexes:
#  docker_registry_mirror_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  docker_registry_mirror_vm_id_fkey | (vm_id) REFERENCES vm(id)
