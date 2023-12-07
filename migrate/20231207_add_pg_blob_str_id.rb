# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :blob_storage_id, :uuid, null: true
    end
  end
end
