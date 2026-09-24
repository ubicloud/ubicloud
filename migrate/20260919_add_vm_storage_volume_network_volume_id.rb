# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:vm_storage_volume) do
      add_foreign_key :network_volume_id, :network_volume, type: :uuid
    end
  end
end
