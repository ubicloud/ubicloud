# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_column :track_written, :bool, default: false, null: false
    end
  end
end
