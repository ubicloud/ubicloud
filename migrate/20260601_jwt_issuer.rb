# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:jwt_issuer) do
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(604)") # "jw" ubid type
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :account_id, :accounts, type: :uuid, null: false
      column :name, :text, null: false, collate: '"C"'
      column :issuer, :text, null: false, collate: '"C"'
      column :jwks_uri, :text, null: false, collate: '"C"'
      column :audience, :text, collate: '"C"'
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique [:project_id, :issuer]
    end
  end
end
