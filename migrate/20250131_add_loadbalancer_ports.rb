# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:load_balancer_port) do
      uuid :id, primary_key: true
      uuid :load_balancer_id, null: false
      Integer :src_port, null: false
      Integer :dst_port, null: false
      String :health_check_endpoint, text: true, null: false, default: "/up"
      Integer :health_check_interval, null: false, default: 30
      Integer :health_check_timeout, null: false, default: 15
      Integer :health_check_up_threshold, null: false, default: 3
      Integer :health_check_down_threshold, null: false, default: 2
      String :health_check_protocol, text: true, null: false, default: "http"

      foreign_key [:load_balancer_id], :load_balancer, key: :id
      index [:load_balancer_id, :src_port, :dst_port], unique: true, name: :lb_port_unique_index

      check Sequel.lit("health_check_timeout > 0"), name: :chk_health_check_timeout
      check Sequel.lit("health_check_interval > 0 AND health_check_interval < 600"), name: :chk_health_check_interval
      check Sequel.lit("health_check_timeout <= health_check_interval"), name: :chk_timeout_interval
      check Sequel.lit("health_check_up_threshold > 0"), name: :chk_health_check_up_threshold
      check Sequel.lit("health_check_down_threshold > 0"), name: :chk_health_check_down_threshold
    end

    create_table(:load_balancer_vm_port) do
      uuid :id, primary_key: true
      uuid :load_balancer_id, null: false
      uuid :load_balancer_port_id, null: false
      uuid :vm_id, null: false
      String :state, text: true, null: false, default: "down"
      DateTime :last_checked_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key [:load_balancer_port_id], :load_balancer_port, key: :id
      foreign_key [:load_balancer_id], :load_balancer, key: :id, on_delete: :cascade
      foreign_key [:vm_id], :vm, key: :id

      index [:load_balancer_port_id, :vm_id], unique: true, name: :lb_vm_port_unique_index
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

  down do
    drop_table(:load_balancer_vm_port)
    drop_table(:load_balancer_port)

    alter_table(:load_balancer) do
      add_column :src_port, Integer, null: false
      add_column :dst_port, Integer, null: false
      add_column :health_check_endpoint, String, text: true, null: false, default: "/up"
      add_column :health_check_interval, Integer, null: false, default: 30
      add_column :health_check_timeout, Integer, null: false, default: 15
      add_column :health_check_up_threshold, Integer, null: false, default: 3
      add_column :health_check_down_threshold, Integer, null: false, default: 2
      add_column :health_check_protocol, String, text: true, null: false, default: "http"
    end
  end
end

# Sequel.migration do
#   up do
#     run <<-SQL
#       INSERT INTO load_balancer_port (
#         id,
#         load_balancer_id,
#         src_port,
#         dst_port,
#         health_check_endpoint,
#         health_check_interval,
#         health_check_timeout,
#         health_check_up_threshold,
#         health_check_down_threshold,
#         health_check_protocol
#       )
#       SELECT gen_random_uuid(),
#              id,
#              src_port,
#              dst_port,
#              health_check_endpoint,
#              health_check_interval,
#              health_check_timeout,
#              health_check_up_threshold,
#              health_check_down_threshold,
#              health_check_protocol
#       FROM load_balancer;
#     SQL

#     run <<-SQL
#       INSERT INTO load_balancers_vms_ports (
#         id,
#         load_balancer_id,
#         load_balancer_port_id,
#         vm_id,
#         state,
#         last_checked_at
#       )
#       SELECT gen_random_uuid(),
#              lvm.load_balancer_id,
#              lbp.id,
#              lvm.vm_id,
#              lvm.state::text,
#              CURRENT_TIMESTAMP
#       FROM load_balancers_vms lvm
#       JOIN load_balancer_port lbp
#         ON lbp.load_balancer_id = lvm.load_balancer_id;
#     SQL
#   end
# end
