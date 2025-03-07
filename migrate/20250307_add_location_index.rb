# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:location) do
      add_index [:project_id, :display_name], name: :location_project_id_display_name_uidx, unique: true, concurrently: true
    end
  end

  down do
    alter_table(:location) do
      drop_index [:project_id, :display_name], name: :location_project_id_display_name_uidx, concurrently: true
    end
  end
end
