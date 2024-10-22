# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:postgres_version, %w[16 17])

    alter_table(:postgres_resource) do
      add_column :version, :postgres_version, null: false, default: "16"
    end
  end
end
