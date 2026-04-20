# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:private_subnet) do
      add_column :firewall_priority, Integer
    end
    # GCP firewall policies use priority values; must be even numbers in
    # range 1000-8998 so odd numbers remain available for internal rules.
    run "ALTER TABLE private_subnet ADD CONSTRAINT private_subnet_firewall_priority_check CHECK (firewall_priority IS NULL OR (firewall_priority >= 1000 AND firewall_priority <= 8998 AND firewall_priority % 2 = 0)) NOT VALID"
  end

  down do
    run "ALTER TABLE private_subnet DROP CONSTRAINT IF EXISTS private_subnet_firewall_priority_check"
    alter_table(:private_subnet) do
      drop_column :firewall_priority
    end
  end
end
