# frozen_string_literal: true

require "excon"
require "jwt"
require "resolv"
require_relative "../model"

class JwtIssuer < Sequel::Model
  plugin ResourceMethods
  include SubjectTag::Cleanup

  JWKS_CACHE_TTL = 300
  # Min seconds between JWKS fetches per URI. kid misses force invalidation, so
  # without this an attacker minting tokens with unknown kids could hammer the issuer
  JWKS_MIN_REFETCH = 30
  JWKS_CACHE = {}
  JWKS_CACHE_MUTEX = Mutex.new
  JWKS_FETCH_TIMEOUTS = {connect_timeout: 5, read_timeout: 5, write_timeout: 5}.freeze
  # Tolerate small clock skew between issuer and verifier
  CLOCK_LEEWAY = 30
  # Asymmetric algorithms only; HMAC excluded to prevent key confusion against public JWKS
  ALLOWED_ALGORITHMS = %w[RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512].freeze

  def path
    "/token/jwt-issuer/#{ubid}/access-control"
  end

  def validate
    super
    validates_presence [:name, :issuer, :jwks_uri]

    validates_format(Validation::ALLOWED_NAME_PATTERN, :name, message: "must only contain lowercase letters, numbers, and hyphens and have max length 63.", allow_nil: true)

    if jwks_uri && !jwks_uri.empty?
      errors.add(:jwks_uri, "must be a valid https URL") unless self.class.valid_jwks_uri?(jwks_uri)
    end
  end

  def decode_jwt(token)
    opts = {
      algorithms: ALLOWED_ALGORITHMS,
      iss: issuer,
      verify_iss: true,
      required_claims: ["exp"],
      leeway: CLOCK_LEEWAY,
      jwks: jwks_loader,
    }
    if audience
      opts[:aud] = audience
      opts[:verify_aud] = true
    end
    JWT.decode(token, nil, true, **opts)[0]
  end

  def self.valid_jwks_uri?(uri)
    parsed = URI.parse(uri)
    host = parsed.hostname.to_s
    # Require a domain name. Reject IP literals: any legitimate issuer has a hostname,
    # and rejecting literals avoids SSRF against private / loopback / link-local addresses
    parsed.is_a?(URI::HTTPS) && !host.empty? &&
      !(host.match?(Resolv::IPv4::Regex) || host.match?(Resolv::IPv6::Regex))
  rescue URI::InvalidURIError
    false
  end

  def self.fetch_jwks(uri, invalidate:)
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    entry = JWKS_CACHE_MUTEX.synchronize { JWKS_CACHE[uri] }
    if entry && (now - entry[:at] < JWKS_MIN_REFETCH || (!invalidate && now - entry[:at] <= JWKS_CACHE_TTL))
      return entry
    end

    entry = JSON.parse(Excon.get(uri, expects: [200], **JWKS_FETCH_TIMEOUTS).body)
    entry[:at] = now
    JWKS_CACHE_MUTEX.synchronize { JWKS_CACHE[uri] = entry }
  rescue Excon::Error, JSON::ParserError => e
    raise JWT::DecodeError, "Failed to fetch JWKS from #{uri}: #{e.message}"
  end

  private

  def jwks_loader
    lambda do |options|
      self.class.fetch_jwks(jwks_uri, invalidate: options[:invalidate])
    end
  end
end

# Table: jwt_issuer
# Columns:
#  id         | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(604)
#  project_id | uuid                     | NOT NULL
#  account_id | uuid                     | NOT NULL
#  name       | text                     | NOT NULL
#  issuer     | text                     | NOT NULL
#  jwks_uri   | text                     | NOT NULL
#  audience   | text                     |
#  created_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  jwt_issuer_pkey                  | PRIMARY KEY btree (id)
#  jwt_issuer_project_id_issuer_key | UNIQUE btree (project_id, issuer)
# Foreign key constraints:
#  jwt_issuer_account_id_fkey | (account_id) REFERENCES accounts(id)
#  jwt_issuer_project_id_fkey | (project_id) REFERENCES project(id)
