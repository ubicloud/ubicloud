# frozen_string_literal: true

require_relative "../model"

class VmHostCpu < Sequel::Model
  unrestrict_primary_key

  many_to_one :vm_host
end

# Table: vm_host_cpu
# Primary Key: (vm_host_id, cpu_number)
# Columns:
#  vm_host_id       | uuid    |
#  cpu_number       | integer |
#  spdk             | boolean | NOT NULL
#  vm_host_slice_id | uuid    |
# Indexes:
#  vm_host_cpu_pkey | PRIMARY KEY btree (vm_host_id, cpu_number)
# Foreign key constraints:
#  vm_host_cpu_vm_host_id_fkey       | (vm_host_id) REFERENCES vm_host(id)
#  vm_host_cpu_vm_host_slice_id_fkey | (vm_host_slice_id) REFERENCES vm_host_slice(id)
