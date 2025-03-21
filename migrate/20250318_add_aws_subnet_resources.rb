# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:private_subnet_aws_resource) do
      column :vpc_id, :text, null: true
      column :subnet_id, :text, null: true
      column :internet_gateway_id, :text, null: true
      column :route_table_id, :text, null: true
      column :security_group_id, :text, null: true
      foreign_key :id, :private_subnet, type: :uuid, null: false, primary_key: true
    end

    alter_table(:assigned_vm_address) do
      set_column_allow_null :address_id
    end

    alter_table(:vm_storage_volume) do
      set_column_allow_null :spdk_installation_id
      set_column_allow_null :storage_device_id
    end
  end
end
