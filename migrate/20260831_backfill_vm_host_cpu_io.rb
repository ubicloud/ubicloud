# frozen_string_literal: true

Sequel.migration do
  up do
    run "UPDATE vm_host_cpu SET io = spdk WHERE io IS NULL"
    alter_table(:vm_host_cpu) do
      set_column_not_null :io
      set_column_allow_null :spdk
    end
  end

  down do
    alter_table(:vm_host_cpu) do
      set_column_not_null :spdk
      set_column_allow_null :io
    end
  end
end
