# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:lb_algorithm, %w[round_robin hash_based])

    create_table(:load_balancer) do
      column :id, :uuid, primary_key: true
      column :name, :text, null: false
      column :algorithm, :lb_algorithm, null: false, default: "round_robin"
      column :src_port, :integer, null: false
      column :dst_port, :integer, null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
    end

    create_table(:load_balancers_vms) do
      foreign_key :load_balancer_id, :load_balancer, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false, unique: true
      primary_key [:load_balancer_id, :vm_id]
    end
  end
end
