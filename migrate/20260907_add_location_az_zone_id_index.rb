# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    add_index :location_az, [:location_id, :zone_id], unique: true, name: :location_az_location_id_zone_id_index, concurrently: true
  end
end
