# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:location_az) do
      set_column_allow_null :zone_id
    end
  end

  down do
    alter_table(:location_az) do
      set_column_not_null :zone_id
    end
  end
end
