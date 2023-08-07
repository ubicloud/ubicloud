# frozen_string_literal: true

Sequel.migration do
  up do
    create_table(:invoice) do
      column :id, :uuid, primary_key: true, default: nil
      column :project_id, :project, type: :uuid, null: false
      column :content, :jsonb, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.lit("now()")
      index :project_id
    end
  end
end
