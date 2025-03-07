# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:load_balancer) do
      drop_column :src_port
      drop_column :dst_port
    end

    alter_table(:load_balancers_vms) do
      drop_column :state
    end
  end

  down do
    alter_table(:load_balancer) do
      add_column :src_port, Integer, null: true
      add_column :dst_port, Integer, null: true
    end

    alter_table(:load_balancers_vms) do
      add_column :state, :lb_node_state, null: false, default: "down"
    end
  end
end
