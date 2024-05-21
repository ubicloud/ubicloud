# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:lb_connection_state, %w[connected disconnected])

    create_table(:load_balancer) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
    end

    create_table(:load_balancers_vms) do
      foreign_key :load_balancer_id, :load_balancer, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false
      column :state, :lb_connection_state, null: false, default: "connected"
      primary_key [:load_balancer_id, :vm_id]
    end
  end
end
