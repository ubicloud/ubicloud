# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:private_subnet_aws_resource) do
      foreign_key :id, :private_subnet, type: :uuid, primary_key: true
      column :vpc_id, :text
      column :subnet_id, :text
      column :internet_gateway_id, :text
      column :route_table_id, :text
      column :security_group_id, :text
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
