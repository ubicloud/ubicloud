# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:load_balancers_ports) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :load_balancer_id, :load_balancer, type: :uuid, on_delete: :cascade
      column :src_port, Integer, null: false
      column :dst_port, Integer, null: false

      column :health_check_endpoint, String, null: false, default: "/up"
      column :health_check_interval, Integer, null: false, default: 30
      column :health_check_timeout, Integer, null: false, default: 15
      column :health_check_up_threshold, Integer, null: false, default: 3
      column :health_check_down_threshold, Integer, null: false, default: 2
      column :health_check_protocol, String, null: false, default: "http"

      check { health_check_down_threshold > 0 }
      check { health_check_interval > 0 }
      check { health_check_interval < 600 }
      check { health_check_timeout > 0 }
      check { health_check_timeout <= health_check_interval }
      check { health_check_up_threshold > 0 }

      index [:load_balancer_id, :src_port, :dst_port], unique: true
    end

    alter_table(:load_balancer) do
      drop_column :src_port
      drop_column :dst_port

      drop_column :health_check_endpoint
      drop_column :health_check_interval
      drop_column :health_check_timeout
      drop_column :health_check_up_threshold
      drop_column :health_check_down_threshold
      drop_column :health_check_protocol
    end
  end
end
