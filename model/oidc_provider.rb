# frozen_string_literal: true

require_relative "../model"
require "base64"
require "excon"
require "jwt"

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
  def self.register(...)
    create(discovery_attributes(...))
  end

  def self.discovery_attributes(display_name, url, client_id:, client_secret:, group_prefix: nil)
    uri = URI(url)
    unless url.end_with?("/.well-known/openid-configuration")
      uri.path += "/.well-known/openid-configuration"
    end
    response = Excon.get(uri.to_s, headers: {"Accept" => "application/json"}, expects: 200)
    config_info = JSON.parse(response.body)
    {
      display_name:,
      url: config_info.fetch("issuer"),
      client_id:,
      client_secret:,
      authorization_endpoint: URI(config_info.fetch("authorization_endpoint")).path,
      token_endpoint: URI(config_info.fetch("token_endpoint")).path,
      userinfo_endpoint: URI(config_info.fetch("userinfo_endpoint")).path,
      jwks_uri: config_info.fetch("jwks_uri"),
      group_prefix:,
      pkce_supported: Array(config_info["code_challenge_methods_supported"]).include?("S256"),
    }
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

  class RefreshError < StandardError; end

  # Returns [groups, rotated_refresh_token_or_nil] on success, nil if the
  # refresh token itself was rejected (e.g. the account was unassigned from
  # the app). Raises RefreshError for anything else (network errors,
  # unexpected statuses, malformed responses) so the caller can distinguish
  # "definitely revoked" from "couldn't check right now".
  def refresh_groups(refresh_token)
    uri = URI(url)
    base_url = "#{uri.scheme}://#{uri.host}:#{uri.port}"
    response = Excon.post(
      "#{base_url}#{token_endpoint}",
      headers: {
        "Authorization" => "Basic #{Base64.strict_encode64([CGI.escape(client_id), CGI.escape(client_secret)].join(":"))}",
        "Content-Type" => "application/x-www-form-urlencoded",
        "Accept" => "application/json",
      },
      body: URI.encode_www_form({"grant_type" => "refresh_token", "refresh_token" => refresh_token}),
      expects: [200, 201, 400],
    )
    token_hash = JSON.parse(response.body)

    if response.status == 400
      # Only invalid_grant means the refresh token itself is dead. Other 400s
      # (invalid_client, invalid_request, misconfiguration) are not a
      # revocation signal and shouldn't be treated as one.
      return nil if token_hash["error"] == "invalid_grant"
      raise RefreshError, "unexpected error response: #{token_hash["error"]}"
    end

    token = JWT.decode(token_hash.fetch("id_token"), nil, false).first
    unless token.is_a?(Hash) && token["iss"] == url && Array(token["aud"]).include?(client_id)
      raise RefreshError, "refreshed id token failed issuer/audience verification"
    end

    # Same lookup order as login: id_token claim, then userinfo.
    if (groups = token[groups_claim]).nil?
      response = Excon.get(
        "#{base_url}#{userinfo_endpoint}",
        headers: {"Authorization" => "Bearer #{token_hash.fetch("access_token")}", "Accept" => "application/json"},
        expects: 200,
      )
      groups = JSON.parse(response.body)[groups_claim]
    end

    [Array(groups).map(&:to_s), token_hash["refresh_token"]]
  rescue Excon::Error, JSON::ParserError, KeyError, JWT::DecodeError => e
    raise RefreshError, e.message
  end

  private

  def allowed_domain_ds
    DB[:allowed_oidc_provider_domain].where(oidc_provider_id: id)
  end
end

# Table: oidc_provider
# Columns:
#  id                        | uuid    | PRIMARY KEY
#  client_id                 | text    | NOT NULL
#  client_secret             | text    | NOT NULL
#  display_name              | text    | NOT NULL
#  url                       | text    | NOT NULL
#  authorization_endpoint    | text    | NOT NULL
#  token_endpoint            | text    | NOT NULL
#  userinfo_endpoint         | text    | NOT NULL
#  jwks_uri                  | text    | NOT NULL
#  registration_client_uri   | text    |
#  registration_access_token | text    |
#  group_prefix              | text    |
#  pkce_supported            | boolean | NOT NULL DEFAULT false
#  groups_claim              | text    |
# Indexes:
#  oidc_provider_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  allowed_oidc_provider_domain | allowed_oidc_provider_domain_oidc_provider_id_fkey | (oidc_provider_id) REFERENCES oidc_provider(id) ON DELETE CASCADE
#  locked_domain                | locked_domain_oidc_provider_id_fkey                | (oidc_provider_id) REFERENCES oidc_provider(id)
