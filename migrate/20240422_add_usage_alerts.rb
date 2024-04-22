# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:usage_alert) do
      column :id, :uuid, primary_key: true
      foreign_key :project_id, :project, type: :uuid, null: false
      column :name, :text, collate: '"C"', null: false
      column :limit, Integer, null: false
      foreign_key :user_id, :accounts, type: :uuid, null: false
      column :last_triggered_at, :timestamptz, null: false, default: Sequel.lit("now() - INTERVAL '42 days'")
      index :last_triggered_at
    end
  end
end
