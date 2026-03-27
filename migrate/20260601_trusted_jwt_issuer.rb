# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:trusted_jwt_issuer) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_uuid()")
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :account_id, :accounts, type: :uuid, null: false
      column :name, :text, null: false
      column :issuer, :text, null: false
      column :jwks_uri, :text, null: false
      column :audience, :text
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique [:project_id, :issuer]
    end
  end
end
