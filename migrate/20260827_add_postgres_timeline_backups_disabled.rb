# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_timeline) do
      add_column :backups_disabled, :boolean, null: false, default: false
    end
  end
end
