# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:vm_host_cpu) do
      drop_column :spdk
    end
  end

  down do
    alter_table(:vm_host_cpu) do
      add_column :spdk, :boolean
    end
    run "UPDATE vm_host_cpu SET spdk = io"
  end
end
