# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:aws_subnet) do
      column :id, :uuid, primary_key: true
      column :subnet_id, :text
      column :availability_zone, :text
      column :ipv_6_cidr_block, :cidr, null: false
      column :ipv_4_cidr_block, :cidr, null: false
      foreign_key :private_subnet_aws_resource_id, :private_subnet_aws_resource, type: :uuid, null: false
    end
  end
end
