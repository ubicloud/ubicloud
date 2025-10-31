# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:load_balancer_vm_port) do
      add_column :stack, :lb_stack, null: false, default: "ipv4"
      add_index [:load_balancer_port_id, :load_balancer_vm_id, :stack], unique: true, name: :lb_vm_port_stack_unique_index
      drop_index [:load_balancer_port_id, :load_balancer_vm_id], name: :lb_vm_port_unique_index
    end
  end

  down do
    alter_table(:load_balancer_vm_port) do
      drop_column :stack
    end
  end
end
