# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:load_balancer_port) do
      uuid :id, primary_key: true
      uuid :load_balancer_id, null: false
      Integer :src_port, null: false
      Integer :dst_port, null: false

      foreign_key [:load_balancer_id], :load_balancer, key: :id
      index [:load_balancer_id, :src_port, :dst_port], unique: true, name: :lb_port_unique_index
    end

    create_table(:load_balancer_vm_port) do
      uuid :id, primary_key: true
      uuid :load_balancer_vm_id, null: false
      uuid :load_balancer_port_id, null: false
      column :state, :lb_node_state, null: false, default: "down"
      DateTime :last_checked_at, null: false, default: Sequel::CURRENT_TIMESTAMP

      foreign_key [:load_balancer_port_id], :load_balancer_port, key: :id
      foreign_key [:load_balancer_vm_id], :load_balancers_vms, key: :id, on_delete: :cascade

      index [:load_balancer_port_id, :load_balancer_vm_id], unique: true, name: :lb_vm_port_unique_index
    end

    alter_table(:load_balancer) do
      set_column_allow_null :src_port
      set_column_allow_null :dst_port
    end

    alter_table(:load_balancers_vms) do
      set_column_allow_null :state
    end
  end

  down do
    drop_table(:load_balancer_vm_port)
    drop_table(:load_balancer_port)

    self[:load_balancer].where(src_port: nil).update(src_port: 80)
    self[:load_balancer].where(dst_port: nil).update(dst_port: 8000)
    alter_table(:load_balancer) do
      set_column_default :src_port, 80
      set_column_default :dst_port, 80

      set_column_not_null :src_port
      set_column_not_null :dst_port
    end

    self[:load_balancers_vms].where(state: nil).update(state: "down")
    alter_table(:load_balancers_vms) do
      set_column_not_null :state
    end
  end
end
