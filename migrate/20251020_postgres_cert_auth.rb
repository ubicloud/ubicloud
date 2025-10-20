# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:postgres_resource) do
      add_column :trusted_ca_certs, :text, null: true
      add_column :cert_auth_users, :jsonb, null: false, default: "[]"
    end
  end
end
