# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_column :use_bdev_ubi, :bool, null: false, default: false
    end
  end
end
