# frozen_string_literal: true

require_relative "../ubid"

Sequel.migration do
  up do
    create_table(:load_balancer_port) do
      uuid :id, primary_key: true
      uuid :load_balancer_id, null: false
      Integer :src_port, null: false
      Integer :dst_port, null: false

      foreign_key [:load_balancer_id], :load_balancer
      index [:load_balancer_id, :src_port], unique: true, name: :lb_port_unique_index

      constraint :src_port_range, src_port: 1..65535
      constraint :dst_port_range, dst_port: 1..65535
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

    DB[:load_balancer_port].import(
      [:id, :load_balancer_id, :src_port, :dst_port],
      DB[:load_balancer].select_map([:id, :src_port, :dst_port]).each { it.unshift(UBID.generate("lp").to_uuid) }
    )

    DB[:load_balancer_vm_port].import([:id, :load_balancer_port_id, :load_balancer_vm_id, :state],
      DB[:load_balancers_vms]
        .join(:load_balancer_port, load_balancer_id: :load_balancer_id)
        .select_map([
          Sequel[:load_balancer_port][:id].as(:load_balancer_port_id),
          Sequel[:load_balancers_vms][:id].as(:load_balancer_vm_id),
          Sequel[:load_balancers_vms][:state]
        ])
        .each { it.unshift(UBID.generate("1q").to_uuid) })
  end

  down do
    DB[:load_balancer].update(
      src_port: Sequel.expr { DB[:load_balancer_port].where(load_balancer_id: Sequel[:load_balancer][:id]).select(:src_port).limit(1) },
      dst_port: Sequel.expr { DB[:load_balancer_port].where(load_balancer_id: Sequel[:load_balancer][:id]).select(:dst_port).limit(1) }
    )
    alter_table(:load_balancer) do
      set_column_not_null :src_port
      set_column_not_null :dst_port
    end

    DB[:load_balancers_vms]
      .update(
        state: Sequel.expr do
          DB[:load_balancer_vm_port]
            .where(load_balancer_vm_id: Sequel[:load_balancers_vms][:id])
            .select(:state)
            .limit(1)
        end
      )
    alter_table(:load_balancers_vms) do
      set_column_not_null :state
    end

    drop_table(:load_balancer_vm_port)
    drop_table(:load_balancer_port)
  end
end
