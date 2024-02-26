# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:ha_type, %w[none async sync])
    create_enum(:synchronization_status, %w[catching_up ready])

    alter_table(:postgres_resource) do
      add_column :ha_type, :ha_type, null: false, default: "none"
    end

    alter_table(:postgres_server) do
      add_column :synchronization_status, :synchronization_status, null: false, default: "ready"
    end
  end
end
