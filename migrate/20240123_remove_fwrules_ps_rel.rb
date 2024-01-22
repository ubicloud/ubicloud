# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
DELETE FROM firewall_rule
WHERE private_subnet_id IS NOT NULL;
    SQL

    alter_table(:firewall_rule) do
      drop_column :private_subnet_id
      set_column_not_null :firewall_id
    end
  end

  down do
    alter_table(:firewall_rule) do
      add_foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: true
      set_column_allow_null :firewall_id
    end
  end
end
