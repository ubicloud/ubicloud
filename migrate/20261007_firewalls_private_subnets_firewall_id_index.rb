# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:firewalls_private_subnets) do
      add_index :firewall_id, concurrently: true
    end
  end
end
