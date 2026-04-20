# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:private_subnet) do
      add_index [:project_id, :location_id, :firewall_priority], unique: true,
        where: Sequel.lit("firewall_priority IS NOT NULL"),
        name: :private_subnet_project_location_firewall_priority_idx,
        concurrently: true
    end
  end

  down do
    alter_table(:private_subnet) do
      drop_index nil, name: :private_subnet_project_location_firewall_priority_idx, concurrently: true
    end
  end
end
