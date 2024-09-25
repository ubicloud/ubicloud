# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:api_key) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :owner_table, :text, collate: '"C"', null: false
      column :owner_id, :uuid, null: false
      column :used_for, :text, null: false
      column :key, :text, collate: '"C"', null: false
      column :is_valid, :boolean, null: false, default: true
      index [:owner_table, :owner_id]
    end
  end
end
