# frozen_string_literal: true

Sequel.migration do
  no_transaction

  revert do
    alter_table(:location_az) do
      add_index [:location_id, :zone_id], unique: true, name: :location_aws_az_location_id_zone_id_index, concurrently: true
    end
  end
end
