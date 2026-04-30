# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :latest_backup_size_in_gib, :bigint
    end
  end
end
