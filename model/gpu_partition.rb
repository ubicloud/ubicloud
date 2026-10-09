# frozen_string_literal: true

require_relative "../model"

class GpuPartition < Sequel::Model
  many_to_one :project, read_only: true

  plugin ResourceMethods, etc_type: true

  def validate
    super
    if project_id && changed_columns.include?(:project_id) && !overlapping_owned_partitions_dataset.empty?
      errors.add(:project_id, "is set for a GPU partition overlapping another one owned by a project")
    end
  end

  def overlapping_owned_partitions_dataset
    pci_device_ids = DB[:gpu_partitions_pci_devices].where(gpu_partition_id: id).select(:pci_device_id)
    GpuPartition
      .where(vm_host_id:)
      .exclude(id:)
      .exclude(project_id: nil)
      .where(id: DB[:gpu_partitions_pci_devices].where(pci_device_id: pci_device_ids).select(:gpu_partition_id))
  end
end

# Table: gpu_partition
# Columns:
#  id           | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  vm_host_id   | uuid    | NOT NULL
#  vm_id        | uuid    |
#  partition_id | integer | NOT NULL
#  gpu_count    | integer | NOT NULL
#  enabled      | boolean | NOT NULL DEFAULT true
#  project_id   | uuid    |
# Indexes:
#  gpu_partition_pkey                        | PRIMARY KEY btree (id)
#  gpu_partition_vm_host_id_partition_id_key | UNIQUE btree (vm_host_id, partition_id)
# Foreign key constraints:
#  gpu_partition_project_id_fkey | (project_id) REFERENCES project(id)
#  gpu_partition_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
#  gpu_partition_vm_id_fkey      | (vm_id) REFERENCES vm(id)
# Referenced By:
#  gpu_partitions_pci_devices | gpu_partitions_pci_devices_gpu_partition_id_fkey | (gpu_partition_id) REFERENCES gpu_partition(id) ON DELETE CASCADE
