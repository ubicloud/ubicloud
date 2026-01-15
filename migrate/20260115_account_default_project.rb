# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:account_default_project) do
      foreign_key :id, :accounts, type: :uuid, primary_key: true, on_delete: :cascade
      foreign_key :project_id, :project, type: :uuid, null: false, on_delete: :cascade, index: true
    end
  end
end
