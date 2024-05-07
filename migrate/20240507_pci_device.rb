# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:pci_device) do
      column :id, :uuid, primary_key: true
      column :slot, :text, null: false
      column :device_class, :text, null: false
      column :vendor, :text, null: false
      column :device, :text, null: false
      column :numa_node, :Integer, null: true
      column :iommu_group, :Integer, null: false
      column :enabled, :bool, null: false, default: true
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: true
      unique [:vm_host_id, :slot]
      index [:vm_id]
    end
  end
end
