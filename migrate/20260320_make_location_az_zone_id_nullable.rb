# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:location_az) do
      set_column_allow_null :zone_id
    end
  end
end
