# frozen_string_literal: true

require_relative "../model"

class VmHostSlice < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :vm_host
  one_to_many :vms

  include ResourceMethods
  include SemaphoreMethods
  semaphore :destroy, :start_after_host_reboot, :checkup
end

# Table: vm_host_slice
# Columns:
#  id                | uuid                     | PRIMARY KEY
#  name              | text                     | NOT NULL
#  enabled           | boolean                  | NOT NULL DEFAULT false
#  is_shared         | boolean                  | NOT NULL DEFAULT false
#  cores             | integer                  | NOT NULL
#  total_cpu_percent | integer                  | NOT NULL
#  used_cpu_percent  | integer                  | NOT NULL
#  total_memory_gib  | integer                  | NOT NULL
#  used_memory_gib   | integer                  | NOT NULL
#  family            | text                     | NOT NULL
#  created_at        | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  vm_host_id        | uuid                     | NOT NULL
# Indexes:
#  vm_host_slice_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  cores_not_negative       | (cores >= 0)
#  cpu_allocation_limit     | (used_cpu_percent <= total_cpu_percent)
#  memory_allocation_limit  | (used_memory_gib <= total_memory_gib)
#  used_cpu_not_negative    | (used_cpu_percent >= 0)
#  used_memory_not_negative | (used_memory_gib >= 0)
# Foreign key constraints:
#  vm_host_slice_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
# Referenced By:
#  vm          | vm_vm_host_slice_id_fkey          | (vm_host_slice_id) REFERENCES vm_host_slice(id)
#  vm_host_cpu | vm_host_cpu_vm_host_slice_id_fkey | (vm_host_slice_id) REFERENCES vm_host_slice(id)
