# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :private_subnet, [:id, :project_id, :location_id], unique: true, concurrently: true, name: :private_subnet_id_project_id_location_id_uidx
  end
end
