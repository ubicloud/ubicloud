# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_host) do
      drop_constraint :core_allocation_limit
    end

    alter_table(:spdk_installation) do
      add_column :core_count, Integer, null: false, default: 1
      add_column :core_offset, Integer, null: false, default: 0
    end
  end
end
