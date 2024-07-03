# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:lb_node_state, %w[up down evacuating])

    alter_table(:load_balancer) do
      add_column :health_check_endpoint, :text, collate: '"C"', null: false
      add_column :health_check_interval, :integer, null: false, default: 10
      add_column :health_check_timeout, :integer, null: false, default: 5
      add_column :health_check_up_threshold, :integer, null: false, default: 5
      add_column :health_check_down_threshold, :integer, null: false, default: 3
      add_constraint(:health_check_up_threshold_gt_0) { health_check_up_threshold > 0 }
      add_constraint(:health_check_down_threshold_gt_0) { health_check_down_threshold > 0 }
      add_constraint(:health_check_timeout_gt_0) { health_check_timeout > 0 }
      add_constraint(:health_check_interval_gt_0) { health_check_interval > 0 }
      add_constraint(:health_check_interval_lt_600) { health_check_interval < 600 }
      add_constraint(:health_check_timeout_lt_health_check_interval) { health_check_timeout <= health_check_interval }
    end

    alter_table(:load_balancers_vms) do
      add_column :state, :lb_node_state, null: false, default: "down"
      add_column :state_counter, Integer, null: false, default: 0
    end
  end
end
