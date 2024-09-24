# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:postgres_flavor, %w[standard paradedb])

    alter_table(:postgres_resource) do
      add_column :flavor, :postgres_flavor, null: false, default: "standard"
    end
  end
end
