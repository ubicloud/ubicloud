# frozen_string_literal: true

Sequel.migration do
  no_transaction

  up do
    alter_table(:private_subnet) do
      drop_index [:location_id, :firewall_priority], name: :private_subnet_location_firewall_priority_idx, concurrently: true
      add_index [:project_id, :firewall_priority], unique: true, concurrently: true,
        where: Sequel.lit("firewall_priority IS NOT NULL"),
        name: :private_subnet_project_firewall_priority_idx
    end

    alter_table(:nic_gcp_resource) do
      add_column :project_id, :uuid
      drop_index [:location_id, :firewall_base_priority], name: :nic_gcp_resource_location_firewall_base_priority_idx, concurrently: true
      add_index [:project_id, :firewall_base_priority], unique: true, concurrently: true,
        where: Sequel.lit("firewall_base_priority IS NOT NULL"),
        name: :nic_gcp_resource_project_firewall_base_priority_idx
    end
  end

  down do
    alter_table(:nic_gcp_resource) do
      drop_index [:project_id, :firewall_base_priority], name: :nic_gcp_resource_project_firewall_base_priority_idx, concurrently: true
      drop_column :project_id
      add_index [:location_id, :firewall_base_priority], unique: true, concurrently: true,
        where: Sequel.lit("firewall_base_priority IS NOT NULL"),
        name: :nic_gcp_resource_location_firewall_base_priority_idx
    end

    alter_table(:private_subnet) do
      drop_index [:project_id, :firewall_priority], name: :private_subnet_project_firewall_priority_idx, concurrently: true
      add_index [:location_id, :firewall_priority], unique: true, concurrently: true,
        where: Sequel.lit("firewall_priority IS NOT NULL"),
        name: :private_subnet_location_firewall_priority_idx
    end
  end
end
