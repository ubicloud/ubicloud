# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_column :max_ios_per_sec, :int, null: true
      add_column :max_read_mbytes_per_sec, :int, null: true
      add_column :max_write_mbytes_per_sec, :int, null: true
    end
  end
end
