# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:private_subnet) do
      add_column :firewall_priority, Integer
    end
    run "CREATE UNIQUE INDEX private_subnet_project_location_firewall_priority_idx ON private_subnet (project_id, location_id, firewall_priority) WHERE firewall_priority IS NOT NULL"
    run "ALTER TABLE private_subnet ADD CONSTRAINT private_subnet_firewall_priority_check CHECK (firewall_priority IS NULL OR (firewall_priority >= 1000 AND firewall_priority <= 8998 AND firewall_priority % 2 = 0))"
  end

  down do
    run "ALTER TABLE private_subnet DROP CONSTRAINT IF EXISTS private_subnet_firewall_priority_check"
    run "DROP INDEX IF EXISTS private_subnet_project_location_firewall_priority_idx"
    alter_table(:private_subnet) do
      drop_column :firewall_priority
    end
  end
end
