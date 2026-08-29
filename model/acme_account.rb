# frozen_string_literal: true

require_relative "../model"

# An ACME account registered at a provider. A provider normally uses one
# account for all its certificates. A per_cert_accounts provider instead
# stores a separate account key on each certificate and has no rows here.
class AcmeAccount < Sequel::Model
  many_to_one :acme_provider

  plugin ResourceMethods, etc_type: true, encrypted_columns: [:account_key]

  # Return the provider's shared account, registering it on first use.
  # Registration holds a row lock on the provider, because some CAs
  # (Google Trust Services, for one) accept an EAB credential for one
  # registration only, so two callers must never both register.
  def self.fetch_or_register(provider)
    first(acme_provider_id: provider.id) || DB.transaction do
      provider.lock!(:no_key_update)
      first(acme_provider_id: provider.id) || begin
        private_key = OpenSSL::PKey::EC.generate("prime256v1")
        kid = provider.register_account(private_key)
        create(acme_provider_id: provider.id, account_key: private_key.to_der, kid:)
      end
    end
  end

  def private_key
    Util.parse_key(account_key)
  end
end

# Table: acme_account
# Columns:
#  id               | uuid                     | PRIMARY KEY
#  acme_provider_id | uuid                     | NOT NULL
#  account_key      | text                     | NOT NULL
#  kid              | text                     | NOT NULL
#  created_at       | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  acme_account_pkey                 | PRIMARY KEY btree (id)
#  acme_account_acme_provider_id_key | UNIQUE btree (acme_provider_id)
# Foreign key constraints:
#  acme_account_acme_provider_id_fkey | (acme_provider_id) REFERENCES acme_provider(id)
