# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:inference_endpoint) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :is_public, :boolean, null: false, default: false
      column :visible, :boolean, null: false, default: true
      column :location, :text, collate: '"C"', null: false
      column :boot_image, :text, collate: '"C"', null: false
      column :name, :text, null: false
      column :vm_size, :text, collate: '"C"', null: false
      column :model_name, :text, collate: '"C"', null: false
      column :storage_volumes, :jsonb, null: false
      column :engine, :text, collate: '"C"', null: false
      column :engine_params, :text, collate: '"C"', null: false
      column :replica_count, :integer, null: false
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :load_balancer_id, :load_balancer, type: :uuid, null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
    end

    create_table(:inference_endpoint_replica) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :inference_endpoint_id, :inference_endpoint, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false, unique: true
    end
  end
end
