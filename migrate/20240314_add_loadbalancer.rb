# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:loadbalancer) do
      column :id, :uuid, primary_key: true
      column :name, :text, collate: '"C"', null: true
      column :ip_list, "inet[]", null: true
      foreign_key :vm_host_id, :vm_host, type: :uuid, null: true
    end

    alter_table(:assigned_vm_address) do
      add_foreign_key :loadbalancer_id, :loadbalancer, type: :uuid, null: true
      set_column_allow_null :dst_vm_id, true
    end
  end
end
