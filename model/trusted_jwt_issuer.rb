# frozen_string_literal: true

require "excon"
require "ipaddr"
require "jwt"
require_relative "../model"

class TrustedJwtIssuer < Sequel::Model
  many_to_one :project, read_only: true
  many_to_one :account, read_only: true

  plugin ResourceMethods

  JWKS_CACHE_TTL = 300
  JWKS_CACHE = {}
  JWKS_CACHE_MUTEX = Mutex.new
  # Tolerate small clock skew between issuer and verifier
  CLOCK_LEEWAY = 30

  def validate
    super
    validates_presence [:name, :issuer, :jwks_uri]

    if jwks_uri && !jwks_uri.empty?
      errors.add(:jwks_uri, "must be a valid https URL") unless self.class.valid_jwks_uri?(jwks_uri)
    end
  end

  def decode_jwt(token)
    opts = {
      algorithms: ["RS256"],
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
    return false unless parsed.is_a?(URI::HTTPS) && parsed.host && !parsed.host.empty?
    # Reject literal private / loopback / link-local hosts. DNS-resolved SSRF
    # would need the resolved IP re-checked at fetch time with pinned socket.
    addr = IPAddr.new(parsed.host)
    !(addr.private? || addr.loopback? || addr.link_local?)
  rescue IPAddr::Error
    # Not a literal IP, treat as public hostname
    true
  rescue URI::InvalidURIError
    false
  end

  def self.fetch_jwks(uri, invalidate:)
    JWKS_CACHE_MUTEX.synchronize do
      entry = JWKS_CACHE[uri]
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if invalidate || entry.nil? || now - entry[:at] > JWKS_CACHE_TTL
        entry = {at: now, jwks: JSON.parse(Excon.get(uri, expects: [200]).body)}
        JWKS_CACHE[uri] = entry
      end
      entry[:jwks]
    end
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

# Table: trusted_jwt_issuer
# Columns:
#  id         | uuid                     | PRIMARY KEY DEFAULT gen_random_uuid()
#  project_id | uuid                     | NOT NULL
#  account_id | uuid                     | NOT NULL
#  name       | text                     | NOT NULL
#  issuer     | text                     | NOT NULL
#  jwks_uri   | text                     | NOT NULL
#  audience   | text                     |
#  created_at | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  trusted_jwt_issuer_pkey                  | PRIMARY KEY btree (id)
#  trusted_jwt_issuer_project_id_issuer_key | UNIQUE btree (project_id, issuer)
# Foreign key constraints:
#  trusted_jwt_issuer_account_id_fkey | (account_id) REFERENCES accounts(id)
#  trusted_jwt_issuer_project_id_fkey | (project_id) REFERENCES project(id)
