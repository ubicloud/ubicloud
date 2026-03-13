# frozen_string_literal: true

Sequel.migration do
  up do
    run "ALTER TABLE nic_gcp_resource DROP CONSTRAINT IF EXISTS nic_gcp_resource_firewall_base_priority_check"
    run "DROP INDEX IF EXISTS nic_gcp_resource_project_firewall_base_priority_idx"

    alter_table(:nic_gcp_resource) do
      drop_column :firewall_base_priority, if_exists: true
      drop_column :project_id, if_exists: true
    end
  end

  down do
    alter_table(:nic_gcp_resource) do
      add_column :project_id, :uuid
      add_column :firewall_base_priority, Integer
    end
    run "CREATE UNIQUE INDEX nic_gcp_resource_project_firewall_base_priority_idx ON nic_gcp_resource (project_id, firewall_base_priority) WHERE firewall_base_priority IS NOT NULL"
    run "ALTER TABLE nic_gcp_resource ADD CONSTRAINT nic_gcp_resource_firewall_base_priority_check CHECK (firewall_base_priority IS NULL OR (firewall_base_priority >= 10000 AND firewall_base_priority <= 59936 AND (firewall_base_priority - 10000) % 64 = 0))"
  end
end
