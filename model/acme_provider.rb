# frozen_string_literal: true

require_relative "../model"

class AcmeProvider < Sequel::Model
  plugin ResourceMethods, etc_type: true, encrypted_columns: [:key]

  # Choose the provider for the given issuance attempt of a certificate.
  # Enabled providers are taken in priority order (highest first),
  # rotated by the attempt number, so that each restart moves to the next
  # CA. A restart also skips the provider the certificate last used, when
  # there is another.
  #
  # If no providers exist, this falls back on using the Config.acme_*
  # variables.
  def self.for_attempt(cert, attempt)
    candidates = where { priority >= 1 }.order(Sequel.desc(:priority), :name).all

    if candidates.empty?
      return new(
        email: Config.acme_email,
        directory_url: Config.acme_directory,
        kid: Config.acme_eab_kid,
        key: Config.acme_eab_hmac_key,
        per_cert_accounts: true,
      )
    end

    chosen = candidates[attempt.to_i % candidates.size]
    if attempt.to_i > 0 && candidates.size > 1 && chosen.id == cert.acme_provider_id
      chosen = candidates[(attempt.to_i + 1) % candidates.size]
    end
    chosen
  end

  def private_key
    Util.parse_key(key)
  end
end

# Table: acme_provider
# Columns:
#  id                | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(474)
#  name              | text    | NOT NULL
#  directory_url     | text    | NOT NULL
#  email             | text    | NOT NULL
#  kid               | text    | NOT NULL
#  key               | text    | NOT NULL
#  per_cert_accounts | boolean | NOT NULL DEFAULT false
#  priority          | integer | NOT NULL
# Indexes:
#  acme_provider_pkey              | PRIMARY KEY btree (id)
#  acme_provider_directory_url_key | UNIQUE btree (directory_url)
#  acme_provider_name_key          | UNIQUE btree (name)
# Referenced By:
#  cert | cert_acme_provider_id_fkey | (acme_provider_id) REFERENCES acme_provider(id)
