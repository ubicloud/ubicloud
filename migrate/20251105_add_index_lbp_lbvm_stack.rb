# frozen_string_literal: true

Sequel.migration do
  no_transaction
  change do
    alter_table(:load_balancer_vm_port) do
      add_index [:load_balancer_port_id, :load_balancer_vm_id, :stack], unique: true, name: :lb_vm_port_stack_unique_index, concurrently: true
    end
  end
end
