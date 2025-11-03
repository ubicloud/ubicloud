# frozen_string_literal: true

Sequel.migration do
  up do
    create_enum(:lb_vm_port_stack, %w[ipv4 ipv6])
    alter_table(:load_balancer_vm_port) do
      add_column :stack, :lb_vm_port_stack, null: false, default: "ipv4"
      add_index [:load_balancer_port_id, :load_balancer_vm_id, :stack], unique: true, name: :lb_vm_port_stack_unique_index # rubocop:disable Sequel/ConcurrentIndex
      drop_index [:load_balancer_port_id, :load_balancer_vm_id], name: :lb_vm_port_unique_index # rubocop:disable Sequel/ConcurrentIndex
    end

    # need to populate extra load_balancer_vm_port records for dual stack load
    # balancers
    # LoadBalancer.select{ it.stack == "dual" }.each do |load_balancer|
    #   load_balancer.load_balancer_vms.each do |load_balancer_vm|
    #     load_balancer.ports.each do |port|
    #       LoadBalancerVmPort.create(load_balancer_vm_id: load_balancer_vm.id, load_balancer_port_id: port.id, stack: "ipv6")
    #     end
    #   end
    # end

    # Update the stack column for load balancer vm ports to ipv6 for ipv6 stack
    # load balancers because the default stack is added as ipv4 above
    run <<~SQL
      UPDATE load_balancer_vm_port SET stack = 'ipv6' WHERE load_balancer_port_id IN (SELECT lb_p.id from load_balancer as lb join load_balancer_port as lb_p on lb.id = lb_p.load_balancer_id where lb.stack = 'ipv6') AND stack = 'ipv4';
    SQL
  end

  down do
    run <<~SQL
      DELETE FROM load_balancer_vm_port WHERE load_balancer_id IN (SELECT id from load_balancer where stack = 'dual') AND stack = 'ipv6';
    SQL

    alter_table(:load_balancer_vm_port) do
      drop_column :stack
      add_index [:load_balancer_port_id, :load_balancer_vm_id], unique: true, name: :lb_vm_port_unique_index # rubocop:disable Sequel/ConcurrentIndex
    end
  end
end
