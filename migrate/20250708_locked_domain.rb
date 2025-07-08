# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:locked_domain) do
      column :domain, String, primary_key: true
      foreign_key :oidc_provider_id, :oidc_provider, type: :uuid, null: false
    end
  end
end
