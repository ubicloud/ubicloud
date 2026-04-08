# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:location_az) do
      add_index [:location_id, :az], unique: true, name: :location_az_location_id_az_index, concurrently: true
    end
  end

  down do
    alter_table(:location_az) do
      drop_index nil, name: :location_az_location_id_az_index, concurrently: true
    end
  end
end
