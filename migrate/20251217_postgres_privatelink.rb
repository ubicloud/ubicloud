# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_privatelink_aws_resource) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :postgres_resource_id, :postgres_resource, type: :uuid, null: false
      column :nlb_arn, :text, null: true
      column :target_group_arn, :text, null: true
      column :listener_arn, :text, null: true
      column :service_id, :text, null: true
      column :service_name, :text, null: true

      index :postgres_resource_id, unique: true
    end
  end
end
