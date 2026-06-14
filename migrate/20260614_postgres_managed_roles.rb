# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:postgres_managed_role) do
      column :id, :uuid, primary_key: true
      foreign_key :postgres_resource_id, :postgres_resource, type: :uuid, null: false
      column :name, :text, null: false
      column :auth_type, :text, null: false
      column :state, :text, null: false, default: "creating"
      column :cert, :text
      column :cert_key, :text
      column :cert_not_after, :timestamptz
      column :last_error, :text
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      index [:postgres_resource_id, :name], name: :postgres_managed_role_resource_id_name_uidx, unique: true

      constraint(:postgres_managed_role_auth_type_check, Sequel.lit("auth_type IN ('password', 'cert')"))
      constraint(:postgres_managed_role_state_check, Sequel.lit("state IN ('creating', 'active', 'destroying')"))
    end
  end
end
