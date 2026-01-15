# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:gpu_partition) do
      # UBID.to_base32_n("et") => 474
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(474)")
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: true, default: nil
      Integer :partition_id, null: false
      Integer :gpu_count, null: false
      Boolean :enabled, null: false, default: true
      unique [:vm_host_id, :partition_id]
    end

    create_table(:gpu_partitions_pci_devices) do
      foreign_key :gpu_partition_id, :gpu_partition, type: :uuid, on_delete: :cascade
      foreign_key :pci_device_id, :pci_device, type: :uuid, on_delete: :cascade
      primary_key [:gpu_partition_id, :pci_device_id]
      index [:pci_device_id, :gpu_partition_id]
    end
  end
end
