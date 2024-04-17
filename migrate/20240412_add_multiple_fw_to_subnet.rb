# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:firewalls_private_subnets) do
      foreign_key :private_subnet_id, :private_subnet, type: :uuid
      foreign_key :firewall_id, :firewall, type: :uuid
      primary_key %i[private_subnet_id firewall_id]
    end

    run <<~SQL
      INSERT INTO firewalls_private_subnets (private_subnet_id, firewall_id)
      SELECT private_subnet_id, id AS firewall_id
      FROM firewall;
    SQL

    alter_table(:firewall) do
      drop_column :private_subnet_id
    end
  end
end
