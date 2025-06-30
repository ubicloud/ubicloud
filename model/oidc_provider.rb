# frozen_string_literal: true

require_relative "../model"

class OidcProvider < Sequel::Model
  plugin ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :client_secret
  end
end

# Table: oidc_provider
# Columns:
#  id                        | uuid | PRIMARY KEY
#  client_id                 | text | NOT NULL
#  client_secret             | text | NOT NULL
#  display_name              | text | NOT NULL
#  url                       | text | NOT NULL
#  authorization_endpoint    | text | NOT NULL
#  token_endpoint            | text | NOT NULL
#  userinfo_endpoint         | text | NOT NULL
#  jwks_uri                  | text | NOT NULL
#  registration_client_uri   | text |
#  registration_access_token | text |
# Indexes:
#  oidc_provider_pkey | PRIMARY KEY btree (id)
