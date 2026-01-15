# frozen_string_literal: true

Sequel.migration do
  up do
    ["ipv6", "ipv4"].each do |stack|
      DB[:load_balancer_vm_port].insert([:load_balancer_vm_id, :load_balancer_port_id, :state, :stack],
        DB[:load_balancer_vm_port].select(:load_balancer_vm_id, :load_balancer_port_id, :state, Sequel.lit("'#{stack}'"))
          .where(load_balancer_port_id: DB[:load_balancer_port].select(:id)
            .where(load_balancer_id: DB[:load_balancer].select(:id)
              .where(stack: ["dual", stack]))).group(:load_balancer_vm_id, :load_balancer_port_id, :state))
    end
  end

  down do
    run <<~SQL
      DELETE FROM load_balancer_vm_port WHERE stack in ('ipv6', 'ipv4')
    SQL
  end
end
