# frozen_string_literal: true

Sequel.migration do
  revert do
    alter_table(:postgres_server) do
      add_column :representative_at, :timestamptz, null: true, default: nil
    end
  end
end
