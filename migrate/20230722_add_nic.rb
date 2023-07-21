# frozen_string_literal: true

Sequel.migration do
  change do
    rename_table(:vm_private_subnet, :private_subnet)

    alter_table(:private_subnet) do
      drop_foreign_key :vm_id
      add_column :state, :text, null: false, default: "creating"
      add_column :name, :text, null: false
      add_column :location, :text, null: false
    end

    create_table(:nic) do
      column :id, :uuid, primary_key: true
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
      column :mac, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :private_ipv4, :cidr, null: false
      column :private_ipv6, :cidr, null: false
      foreign_key :vm_id, :vm, type: :uuid
      column :encryption_key, :text, null: false
      column :name, :text, null: false
    end

    alter_table(:ipsec_tunnel) do
      add_foreign_key :src_nic_id, :nic, type: :uuid
      add_foreign_key :dst_nic_id, :nic, type: :uuid
      drop_column :src_vm_id
      drop_column :dst_vm_id
    end
  end
end
