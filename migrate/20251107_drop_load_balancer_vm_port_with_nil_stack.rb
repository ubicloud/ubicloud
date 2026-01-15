# frozen_string_literal: true

Sequel.migration do
  up do
    run <<~SQL
      DELETE FROM load_balancer_vm_port WHERE stack IS NULL
    SQL

    alter_table(:load_balancer_vm_port) do
      set_column_not_null :stack
    end
  end

  down do
    alter_table(:load_balancer_vm_port) do
      set_column_allow_null :stack
    end

    run <<~SQL
      INSERT INTO load_balancer_vm_port (load_balancer_vm_id, load_balancer_port_id, stack)
      SELECT load_balancer_vm_id, load_balancer_port_id, NULL as stack FROM load_balancer_vm_port GROUP BY load_balancer_vm_id, load_balancer_port_id;
    SQL
  end
end
