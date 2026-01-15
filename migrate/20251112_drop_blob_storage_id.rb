# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_timeline) do
      # We lose the data here, in case we need to roll back this migration,
      # we would need to find correct blob_storage_id from region and project.
      drop_column :blob_storage_id
    end
  end

  down do
    alter_table(:postgres_timeline) do
      add_column :blob_storage_id, :uuid, null: true
    end
  end
end
