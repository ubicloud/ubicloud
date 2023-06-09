# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:vm_storage_volume) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :vm_id, :vm, type: :uuid, null: false
      column :boot, :bool, null: false
      column :size_gib, :bigint, null: false
      column :disk_index, :int, null: false

      unique [:vm_id, :disk_index]
    end

    alter_table(:vm_host) do
      add_constraint(:hugepages_allocation_limit) { used_hugepages_1g <= total_hugepages_1g }
    end
  end
end
