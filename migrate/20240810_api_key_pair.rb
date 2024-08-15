# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:api_key_pair) do
      column :id, :uuid, primary_key: true
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :updated_at, :timestamptz, null: false, default: Sequel.lit("now()")
      column :owner_table, :text, collate: '"C"', null: false
      column :owner_id, :uuid, null: false
      column :key1, :text, collate: '"C"', null: false
      column :key1_hash, :text, collate: '"C"', null: false
      column :key2, :text, collate: '"C"', null: false
      column :key2_hash, :text, collate: '"C"', null: false
      index [:owner_table, :owner_id], unique: true
    end
  end
end
