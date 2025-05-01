# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:discount_code) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :code, :citext, null: false, unique: true
      column :credit_amount, :numeric, null: false
      column :expires_at, :timestamptz, null: false
    end

    create_table(:project_discount_code) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      foreign_key :project_id, :project, type: :uuid, null: false
      foreign_key :discount_code_id, :discount_code, type: :uuid, null: false

      unique [:project_id, :discount_code_id]
    end
  end
end
