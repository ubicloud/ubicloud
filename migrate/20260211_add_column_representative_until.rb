# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:postgres_server) do
      add_column :representative_until, :timestamptz, null: true, default: nil
    end
  end

  down do
    alter_table(:postgres_server) do
      drop_column :representative_until
    end
  end
end
