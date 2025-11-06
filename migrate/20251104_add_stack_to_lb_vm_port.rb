# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:load_balancer_vm_port) do
      set_column_default :id, Sequel.lit("gen_random_ubid_uuid(55)") # UBID.to_base32_n("1q") => 55 ubid type
      add_column :stack, :text, null: true
      add_constraint(:stack_check, Sequel.lit("stack in ('ipv4', 'ipv6')"))
    end
  end

  down do
    alter_table(:load_balancer_vm_port) do
      drop_column :stack
      set_column_default :id, nil
    end
  end
end
