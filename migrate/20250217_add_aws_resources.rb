# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:customer_aws_account) do
      column :id, :uuid, primary_key: true
      column :aws_account_access_key, :text
      column :aws_account_secret_access_key, :text
      column :location, :text
    end

    create_table(:private_subnet_aws_resource) do
      foreign_key :id, :private_subnet, type: :uuid
      column :vpc_id, :text
      column :route_table_id, :text
      column :internet_gateway_id, :text
      column :subnet_id, :text
      foreign_key :customer_aws_account_id, :customer_aws_account, type: :uuid
      primary_key [:id]
    end

    create_table(:nic_aws_resource) do
      foreign_key :id, :nic, type: :uuid
      column :network_interface_id, :text
      column :elastic_ip_id, :text
      column :key_pair_id, :text
      column :instance_id, :text
      foreign_key :customer_aws_account_id, :customer_aws_account, type: :uuid
      primary_key [:id]
    end
  end
end
