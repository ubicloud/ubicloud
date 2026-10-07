# frozen_string_literal: true

Sequel.migration do
  no_transaction

  change do
    alter_table(:firewall_rule) do
      add_index :firewall_id, concurrently: true
    end
  end
end
