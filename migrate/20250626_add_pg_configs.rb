# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :user_config, :jsonb, null: false, default: "{}"
      add_column :pgbouncer_user_config, :jsonb, null: false, default: "{}"
    end
  end
end
