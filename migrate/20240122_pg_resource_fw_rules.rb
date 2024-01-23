# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_firewall_rule) do
      column :id, :uuid, primary_key: true, null: false
      column :cidr, :cidr, null: false
      foreign_key :postgres_resource_id, :postgres_resource, null: false, type: :uuid
      unique [:postgres_resource_id, :cidr]
    end
  end
end
