# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:hostname_version, %w[v1 v2])

    alter_table(:postgres_resource) do
      add_column :hostname_version, :hostname_version, null: false, default: "v1"
    end
  end
end
