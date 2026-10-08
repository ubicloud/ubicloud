# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :postgres_resource, [:id, :private_subnet_id], unique: true, concurrently: true, name: :postgres_resource_id_private_subnet_id_uidx
  end
end
