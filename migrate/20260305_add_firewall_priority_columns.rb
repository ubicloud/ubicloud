# frozen_string_literal: true

Sequel.migration do
  up do
    # Add firewall_priority to private_subnet (GCP only, nullable)
    alter_table(:private_subnet) do
      add_column :firewall_priority, Integer
    end
    run "CREATE UNIQUE INDEX private_subnet_location_firewall_priority_idx ON private_subnet (location_id, firewall_priority) WHERE firewall_priority IS NOT NULL"
    run "ALTER TABLE private_subnet ADD CONSTRAINT private_subnet_firewall_priority_check CHECK (firewall_priority IS NULL OR (firewall_priority >= 1000 AND firewall_priority <= 8998 AND firewall_priority % 2 = 0))"

    # Add location_id and firewall_base_priority to nic_gcp_resource
    alter_table(:nic_gcp_resource) do
      add_column :location_id, :uuid
      add_column :firewall_base_priority, Integer
    end
    run "CREATE UNIQUE INDEX nic_gcp_resource_location_firewall_base_priority_idx ON nic_gcp_resource (location_id, firewall_base_priority) WHERE firewall_base_priority IS NOT NULL"
  end

  down do
    run "DROP INDEX IF EXISTS nic_gcp_resource_location_firewall_base_priority_idx"
    alter_table(:nic_gcp_resource) do
      drop_column :firewall_base_priority
      drop_column :location_id
    end
    run "DROP INDEX IF EXISTS private_subnet_location_firewall_priority_idx"
    alter_table(:private_subnet) do
      drop_column :firewall_priority
    end
  end
end
