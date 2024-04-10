# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:firewall) do
      add_foreign_key :private_subnet_id, :private_subnet, type: :uuid
    end

    run <<~SQL
      UPDATE firewall f
      SET private_subnet_id = (
        SELECT n.private_subnet_id
        FROM nic n
        WHERE n.vm_id = f.vm_id
      );
    SQL
  end

  down do
    run <<~SQL
      UPDATE firewall f
      SET vm_id = (
        SELECT n.vm_id
        FROM nic n
        WHERE n.private_subnet_id = f.private_subnet_id
      );
    SQL

    alter_table(:firewall) do
      drop_column :private_subnet_id
    end
  end
end
