# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:inference_router) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :name, :text, null: false
      column :replica_count, :integer, null: false
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      foreign_key :load_balancer_id, :load_balancer, type: :uuid, null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid, null: false
    end

    create_table(:inference_router_replica) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :inference_router_id, :inference_router, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid, null: false, unique: true
    end

    create_table(:inference_router_target) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :name, :text, null: false
      column :model_name, :text, collate: '"C"', null: false
      column :host, :text, collate: '"C"', null: false
      column :api_key, :text, collate: '"C"', null: false
      column :inflight_limit, :integer, null: false
      column :priority, :integer, null: false
      column :tags, :jsonb, null: false, default: "{}"
      foreign_key :inference_router_id, :inference_router, type: :uuid, null: false
    end
  end
end
