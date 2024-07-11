# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :private_subnet_id, :uuid
    end
  end
end
