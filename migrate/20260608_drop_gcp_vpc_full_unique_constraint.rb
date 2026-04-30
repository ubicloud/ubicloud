# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:gcp_vpc) do
      drop_constraint :gcp_vpc_project_id_location_id_key, type: :unique
    end
  end

  down do
    alter_table(:gcp_vpc) do
      add_unique_constraint [:project_id, :location_id], name: :gcp_vpc_project_id_location_id_key
    end
  end
end
