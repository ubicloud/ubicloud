# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:load_balancers_vms) do
      set_column_not_null :id
      drop_column :state_counter
      drop_constraint :load_balancers_vms_pkey
      add_primary_key [:id]
    end
  end

  down do
    alter_table(:load_balancers_vms) do
      add_column :state_counter, Integer, null: false, default: 0
      drop_constraint :load_balancers_vms_pkey
      add_constraint :load_balancers_vms_pkey, [:load_balancer_id, :vm_id]
      set_column_allow_null :id
    end
  end
end
