# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:firewall) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false, default: "Default"
      column :description, :text, null: false, default: "Default firewall"
      column :created_at, :timestamp, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :vm_id, :vm, type: :uuid, null: true
    end

    alter_table(:firewall_rule) do
      add_foreign_key :firewall_id, :firewall, null: true, type: :uuid
      rename_column :ip, :cidr
      set_column_allow_null :private_subnet_id
      add_unique_constraint [:cidr, :port_range, :firewall_id]
    end

    run <<~SQL
INSERT INTO firewall (id, name, description, vm_id)
SELECT id, 'Default', 'Default firewall', id FROM vm;
    SQL

    # populate firewall rules per vm
    run <<~SQL
WITH vm_subnet_mapping AS (
  SELECT
      vm.id AS vm_id,
      nic.private_subnet_id
  FROM
      vm
  INNER JOIN
      nic ON vm.id = nic.vm_id
),
new_firewall_rules AS (
    SELECT
        gen_random_uuid() AS id, -- Generate new UUIDs for the id
        fwr.cidr as cidr,
        fwr.port_range as port_range,
        vm_subnet_mapping.vm_id AS firewall_id
    FROM
        firewall_rule fwr
    INNER JOIN
        vm_subnet_mapping ON vm_subnet_mapping.private_subnet_id = fwr.private_subnet_id
)
INSERT INTO firewall_rule (id, cidr, port_range, firewall_id)
SELECT id, cidr, port_range, firewall_id FROM new_firewall_rules;
    SQL
  end

  down do
    # Populate the private_subnet_id column
    run <<~SQL
      UPDATE firewall_rule fr
      SET private_subnet_id = (
        SELECT n.private_subnet_id
        FROM nic n
        INNER JOIN vm ON vm.id = n.vm_id
        INNER JOIN firewall f ON f.vm_id = vm.id
        WHERE f.id = fr.firewall_id
        LIMIT 1
      )
      WHERE fr.firewall_id IS NOT NULL;
    SQL

    # Remove duplicates, keeping only one rule per subnet
    run <<~SQL
      DELETE FROM firewall_rule
      WHERE ctid NOT IN (
        SELECT MIN(ctid)
        FROM firewall_rule
        GROUP BY private_subnet_id, cidr, port_range
      );
    SQL

    # Remove the firewall_id column from firewall_rule
    alter_table(:firewall_rule) do
      drop_column :firewall_id
      set_column_not_null :private_subnet_id
      add_unique_constraint [:cidr, :port_range, :private_subnet_id]
    end

    # Drop the firewall table
    drop_table(:firewall)
  end
end
