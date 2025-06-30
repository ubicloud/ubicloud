# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:oidc_provider) do
      column :id, :uuid, primary_key: true
      column :client_id, String, null: false
      column :client_secret, String, null: false
      column :display_name, String, null: false
      column :url, String, null: false
      column :authorization_endpoint, String, null: false
      column :token_endpoint, String, null: false
      column :userinfo_endpoint, String, null: false
      column :jwks_uri, String, null: false
      column :registration_client_uri, String
      column :registration_access_token, String
    end
  end
end
