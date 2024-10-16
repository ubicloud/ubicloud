# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :connected_subnet do
      column :id, :uuid, primary_key: true, null: false
      foreign_key :subnet_id_1, :private_subnet, type: :uuid, null: false
      foreign_key :subnet_id_2, :private_subnet, type: :uuid, null: false

      # Ensure no duplicate pairs regardless of order
      constraint(:unique_subnet_pair) { (subnet_id_1 < subnet_id_2) }
      unique [:subnet_id_1, :subnet_id_2]
      index [:subnet_id_2]
    end
  end
end
