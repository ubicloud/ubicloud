# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:page) do
      column :id, :uuid, primary_key: true, default: nil
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :resolved_at, :timestamptz
      column :summary, :text, collate: '"C"'
    end
  end
end
