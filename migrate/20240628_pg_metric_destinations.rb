# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_metric_destination) do
      column :id, :uuid, primary_key: true
      foreign_key :postgres_resource_id, :postgres_resource, type: :uuid, null: false
      column :url, :text, null: false
      column :username, :text, null: false
      column :password, :text, null: false
    end
  end
end
