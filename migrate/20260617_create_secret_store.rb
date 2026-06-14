# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:secret_store) do
      # UBID.to_base32_n("ss") => 825
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(825)")
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, :text, null: false
      column :description, :text
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:project_id, :name], unique: true
    end

    create_table(:secret) do
      # UBID.to_base32_n("se") => 814
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(814)")
      foreign_key :secret_store_id, :secret_store, type: :uuid, null: false
      column :key, :text, null: false
      # Encrypted at rest via the column_encryption plugin (see model/secret.rb).
      column :value, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:secret_store_id, :key], unique: true
    end
  end
end
