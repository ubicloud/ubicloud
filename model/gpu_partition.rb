# frozen_string_literal: true

require_relative "../model"

class GpuPartition < Sequel::Model
  many_to_one :vm_host
  one_to_one :vm, key: :id, primary_key: :vm_id
  many_to_many :pci_devices

  plugin ResourceMethods, etc_type: true
end

# Table: gpu_partition
# Columns:
#  id           | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  vm_host_id   | uuid    | NOT NULL
#  vm_id        | uuid    |
#  partition_id | integer | NOT NULL
#  gpu_count    | integer | NOT NULL
#  enabled      | boolean | NOT NULL DEFAULT true
# Indexes:
#  gpu_partition_pkey                        | PRIMARY KEY btree (id)
#  gpu_partition_vm_host_id_partition_id_key | UNIQUE btree (vm_host_id, partition_id)
# Foreign key constraints:
#  gpu_partition_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
#  gpu_partition_vm_id_fkey      | (vm_id) REFERENCES vm(id)
# Referenced By:
#  gpu_partitions_pci_devices | gpu_partitions_pci_devices_gpu_partition_id_fkey | (gpu_partition_id) REFERENCES gpu_partition(id) ON DELETE CASCADE
