# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_error_notification) do
      foreign_key :installation_id, :github_installation, type: :uuid, null: false, on_delete: :cascade
      foreign_key :repository_id, :github_repository, type: :uuid, on_delete: :cascade
      column :error, :text, null: false
      column :notified_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP
      index [:installation_id, :repository_id, :error], unique: true, nulls_distinct: false
    end
  end
end
