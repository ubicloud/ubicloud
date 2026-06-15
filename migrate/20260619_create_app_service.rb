# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:app_resource) do
      # UBID.to_base32_n("ar") => 344
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(344)")
      # The user-facing handle lives in the customer's project; all backing
      # resources (subnet, secret store, servers) live in the app service project.
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :location_id, :location, type: :uuid, null: false
      column :name, :text, null: false
      column :repo_url, :text, null: false
      column :branch, :text, null: false
      column :target_vm_size, :text, null: false
      foreign_key :private_subnet_id, :private_subnet, type: :uuid
      foreign_key :secret_store_id, :secret_store, type: :uuid
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:project_id, :location_id, :name], unique: true
    end

    create_table(:app_server) do
      # UBID.to_base32_n("ap") => 342
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(342)")
      foreign_key :app_resource_id, :app_resource, type: :uuid, null: false
      foreign_key :vm_id, :vm, type: :uuid
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :app_resource_id
    end
  end
end
