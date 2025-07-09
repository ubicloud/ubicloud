# frozen_string_literal: true

require_relative "../model"
require "excon"

class OidcProvider < Sequel::Model
  one_to_many :locked_domains

  def self.name_for_ubid(ubid)
    OidcProvider[UBID.to_uuid(ubid)]&.display_name
  end

  # Register a new OIDC Provider using their OIDC discovery information.
  # If the customer who wants to use the provider provides a client ID and
  # client secret, pass those.  If the OIDC provider supports anonymous
  # dynamic client registration, you don't need to provide a client id
  # and secret, and this will use dynamic client registration to register
  # a new client. If the OIDC provider does not provide OIDC discovery
  # information, you'll need to be provided all OIDC information and
  # create the instance manually using OidcProvider.create.
  def self.register(display_name, url, client_id: nil, client_secret: nil)
    oidc_provider = new_with_id(display_name:)

    uri = URI(url)
    uri.path = "/.well-known/openid-configuration"
    response = Excon.get(uri.to_s, headers: {"Accept" => "application/json"}, expects: 200)
    config_info = JSON.parse(response.body)
    authorization_endpoint = URI(config_info.fetch("authorization_endpoint")).path
    token_endpoint = URI(config_info.fetch("token_endpoint")).path
    userinfo_endpoint = URI(config_info.fetch("userinfo_endpoint")).path
    jwks_uri = config_info.fetch("jwks_uri")

    unless client_id && client_secret
      response = Excon.post(config_info["registration_endpoint"],
        headers: {"Accept" => "application/json", "Content-Type" => "application/json"},
        body: {
          client_name: "Ubicloud",
          redirect_uris: [oidc_provider.callback_url],
          scopes: "openid email"
        }.to_json)

      registration_info = JSON.parse(response.body)
      raise "Unable to register with oidc provider: #{response.status} #{registration_info.inspect}" unless response.status == 201
      client_id = registration_info.fetch("client_id")
      client_secret = registration_info.fetch("client_secret")
      registration_client_uri = registration_info["registration_client_uri"]
      registration_access_token = registration_info["registration_access_token"]
    end

    uri.path = ""
    oidc_provider.update(
      url: uri.to_s,
      client_id:,
      client_secret:,
      authorization_endpoint:,
      token_endpoint:,
      userinfo_endpoint:,
      jwks_uri:,
      registration_client_uri:,
      registration_access_token:
    )
  end

  plugin ResourceMethods, encrypted_columns: [:client_secret, :registration_access_token]

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
# Referenced By:
#  locked_domain | locked_domain_oidc_provider_id_fkey | (oidc_provider_id) REFERENCES oidc_provider(id)
