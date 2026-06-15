# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:app_deployment) do
      # UBID.to_base32_n("ay") => 350
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(350)")
      foreign_key :app_resource_id, :app_resource, type: :uuid, null: false
      column :version, :integer, null: false
      column :commit_sha, :text
      column :status, :text, null: false, default: "pending"
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:app_resource_id, :version], unique: true
    end

    alter_table(:app_resource) do
      add_foreign_key :current_deployment_id, :app_deployment, type: :uuid
    end

    alter_table(:app_server) do
      add_foreign_key :current_deployment_id, :app_deployment, type: :uuid
    end
  end
end
