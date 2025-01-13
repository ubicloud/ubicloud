# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :vm_host_cpu do
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: false
      Integer :cpu_number, null: false
      Boolean :spdk, null: false
      foreign_key :vm_host_slice_id, :vm_host_slice, type: :uuid, null: true

      primary_key [:vm_host_id, :cpu_number]
    end
  end
end
