# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_timeline) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      foreign_key :parent_id, :postgres_timeline, type: :uuid
      column :access_key, :text, collate: '"C"'
      column :secret_key, :text, collate: '"C"'
    end
  end
end
