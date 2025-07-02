# frozen_string_literal: true

require_relative "../model"
require "excon"

class OidcProvider < Sequel::Model
  def self.name_for_ubid(ubid)
    OidcProvider[UBID.to_uuid(ubid)]&.display_name
  end

  # Register a new OIDC Provider. Currently, you must restart the application after
  # adding the provider (or require clover.rb to be reloaded).
  def self.register(display_name, url)
    oidc_provider = new_with_id(display_name:)

    uri = URI(url)
    uri.path = "/.well-known/openid-configuration"
    response = Excon.get(uri.to_s,
      headers: {"Accept" => "application/json"},
      expects: 200)

    info = JSON.parse(response.body)
    response = Excon.post(info["registration_endpoint"],
      headers: {"Accept" => "application/json", "Content-Type" => "application/json"},
      body: {
        client_name: "Ubicloud",
        redirect_uris: [oidc_provider.callback_url],
        scopes: "openid email"
      }.to_json)

    info = JSON.parse(response.body)
    raise "Unable to register with oidc provider: #{response.status} #{info.inspect}" unless response.status == 201

    uri.path = ""
    oidc_provider.update(url: uri, client_id: info["client_id"], client_secret: info["client_secret"])
  end

  plugin ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :client_secret
  end

  def callback_url
    "#{Config.base_url}/auth/#{ubid}/callback"
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
