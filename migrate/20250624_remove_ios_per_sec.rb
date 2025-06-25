# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      drop_column :max_ios_per_sec
    end
  end
end
