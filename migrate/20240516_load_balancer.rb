# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:lb_node_state, %w[healthy unhealthy])
    create_enum(:lb_algorithm, %w[round_robin source_hash])

    create_table(:load_balancer) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :hostname, :text, null: false
      column :protocol, :text, null: false
      column :algorithm, :lb_algorithm, null: false, default: "round_robin"
      column :src_port, :integer
      column :dst_port, :integer
      column :health_check_endpoint, :text
      column :health_check_interval, :integer
      column :health_check_timeout, :integer
      column :health_check_unhealthy_threshold, :integer
      column :health_check_healthy_threshold, :integer
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
    end

    create_table(:load_balancers_vms) do
      foreign_key :load_balancer_id, :load_balancer, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false
      column :state, :lb_node_state, null: false, default: "unhealthy"
      column :state_counter, :integer, null: false, default: 0
      primary_key [:load_balancer_id, :vm_id]
    end
  end
end
