# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_foreign_key [:private_subnet_id], :private_subnet, name: :postgres_resource_private_subnet_id_fkey
    end
  end
end
