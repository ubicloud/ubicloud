# frozen_string_literal: true

require_relative "../model"
require "excon"

class OidcProvider < Sequel::Model
  one_to_many :locked_domains, remover: nil, clearer: nil

  def self.name_for_ubid(ubid)
    self[ubid]&.display_name
  end

  def self.identity_name_hash(ids)
    where(id: ids).select_hash(:id, :display_name)
  end

  # Register a new OIDC Provider using their OIDC discovery information.
  # If the customer who wants to use the provider provides a client ID and
  # client secret, pass those.  If the OIDC provider supports anonymous
  # dynamic client registration, you don't need to provide a client id
  # and secret, and this will use dynamic client registration to register
  # a new client. If the OIDC provider does not provide OIDC discovery
  # information, you'll need to be provided all OIDC information and
  # create the instance manually using OidcProvider.create.
  def self.register(display_name, url, client_id:, client_secret:, group_prefix: nil)
    uri = URI(url)
    unless url.end_with?("/.well-known/openid-configuration")
      uri.path += "/.well-known/openid-configuration"
    end
    response = Excon.get(uri.to_s, headers: {"Accept" => "application/json"}, expects: 200)
    config_info = JSON.parse(response.body)
    url = config_info.fetch("issuer")
    authorization_endpoint = URI(config_info.fetch("authorization_endpoint")).path
    token_endpoint = URI(config_info.fetch("token_endpoint")).path
    userinfo_endpoint = URI(config_info.fetch("userinfo_endpoint")).path
    jwks_uri = config_info.fetch("jwks_uri")

    create(
      display_name:,
      url:,
      client_id:,
      client_secret:,
      authorization_endpoint:,
      token_endpoint:,
      userinfo_endpoint:,
      jwks_uri:,
      group_prefix:,
    )
  end

  plugin ResourceMethods, encrypted_columns: [:client_secret, :registration_access_token]

  def allowed_domain?(domain)
    !allowed_domain_ds.where(domain:).empty?
  end

  def allowed_domains
    allowed_domain_ds.select_order_map(:domain)
  end

  def add_allowed_domain(domain)
    allowed_domain_ds.insert(oidc_provider_id: id, domain:)
  end

  def remove_allowed_domain(domain)
    allowed_domain_ds.where(domain:).delete
  end

  def callback_url
    "#{Config.base_url}/auth/#{ubid}/callback"
  end

  private

  def allowed_domain_ds
    DB[:allowed_oidc_provider_domain].where(oidc_provider_id: id)
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
#  group_prefix              | text |
# Indexes:
#  oidc_provider_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  allowed_oidc_provider_domain | allowed_oidc_provider_domain_oidc_provider_id_fkey | (oidc_provider_id) REFERENCES oidc_provider(id) ON DELETE CASCADE
#  locked_domain                | locked_domain_oidc_provider_id_fkey                | (oidc_provider_id) REFERENCES oidc_provider(id)
