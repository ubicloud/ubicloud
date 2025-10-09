# frozen_string_literal: true

require_relative "../model"

class PciDevice < Sequel::Model
  many_to_one :vm_host
  many_to_one :vm

  def self.device_name(device_id)
    # https://download.nvidia.com/XFree86/Linux-x86_64/580.95.05/README/supportedchips.html
    case device_id
    when "20b5"
      "NVIDIA A100 80GB PCIe"
    when "27b0"
      "NVIDIA RTX 4000 SFF Ada Generation"
    when "2901"
      "NVIDIA B200"
    else
      "PCI device"
    end
  end

  plugin ResourceMethods, etc_type: true

  def is_gpu
    ["0300", "0302"].include? device_class
  end

  def name
    PciDevice.device_name(device)
  end
end

# Table: pci_device
# Columns:
#  id           | uuid    | PRIMARY KEY
#  slot         | text    | NOT NULL
#  device_class | text    | NOT NULL
#  vendor       | text    | NOT NULL
#  device       | text    | NOT NULL
#  numa_node    | integer |
#  iommu_group  | integer | NOT NULL
#  enabled      | boolean | NOT NULL DEFAULT true
#  vm_host_id   | uuid    | NOT NULL
#  vm_id        | uuid    |
# Indexes:
#  pci_device_pkey                | PRIMARY KEY btree (id)
#  pci_device_vm_host_id_slot_key | UNIQUE btree (vm_host_id, slot)
#  pci_device_vm_id_index         | btree (vm_id)
# Foreign key constraints:
#  pci_device_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id)
#  pci_device_vm_id_fkey      | (vm_id) REFERENCES vm(id)
