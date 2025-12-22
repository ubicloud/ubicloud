# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:privatelink_aws_resource) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
      column :nlb_arn, :text, null: true
      column :service_id, :text, null: true
      column :service_name, :text, null: true

      index :private_subnet_id, unique: true
    end

    create_table(:privatelink_aws_port) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :privatelink_aws_resource_id, :privatelink_aws_resource,
        type: :uuid, null: false, on_delete: :cascade
      column :src_port, :integer, null: false
      column :dst_port, :integer, null: false
      column :target_group_arn, :text, null: true
      column :listener_arn, :text, null: true

      index [:privatelink_aws_resource_id, :src_port], unique: true
      constraint :src_port_range, Sequel.lit("src_port >= 1 AND src_port <= 65535")
      constraint :dst_port_range, Sequel.lit("dst_port >= 1 AND dst_port <= 65535")
    end

    create_table(:privatelink_aws_vm) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :privatelink_aws_resource_id, :privatelink_aws_resource,
        type: :uuid, null: false, on_delete: :cascade
      foreign_key :vm_id, :vm, type: :uuid, null: false

      index [:privatelink_aws_resource_id, :vm_id], unique: true, name: :pl_vm_unique_idx
    end

    create_table(:privatelink_aws_vm_port) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :privatelink_aws_vm_id, :privatelink_aws_vm,
        type: :uuid, null: false, on_delete: :cascade
      foreign_key :privatelink_aws_port_id, :privatelink_aws_port,
        type: :uuid, null: false, on_delete: :cascade
      column :state, :text, null: false, default: "registering"

      index [:privatelink_aws_vm_id, :privatelink_aws_port_id],
        unique: true, name: :pl_vm_port_unique_idx
      constraint :state_check, Sequel.lit("state IN ('registering', 'registered', 'deregistering', 'deregistered')")
    end
  end
end
