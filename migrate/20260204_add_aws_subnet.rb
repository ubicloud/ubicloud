# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:aws_subnet) do
      # UBID.to_base32_n("as") => 345
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(345)")
      column :subnet_id, :text, null: true  # NULL until AWS subnet is actually created
      column :ipv4_cidr, :cidr, null: false
      column :ipv6_cidr, :cidr, null: true  # NULL until VPC is created and IPv6 block assigned

      foreign_key :private_subnet_aws_resource_id, :private_subnet_aws_resource, type: :uuid, null: false, on_delete: :cascade
      foreign_key :location_aws_az_id, :location_aws_az, type: :uuid, null: false

      unique [:private_subnet_aws_resource_id, :location_aws_az_id]
      index :private_subnet_aws_resource_id
    end

    alter_table(:nic_aws_resource) do
      add_foreign_key :aws_subnet_id, :aws_subnet, type: :uuid, null: true
    end
  end
end
