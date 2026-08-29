# frozen_string_literal: true

require_relative "../model"

# An ACME account registered at a provider. A provider normally uses one
# account for all its certificates. A per_cert_accounts provider instead
# stores a separate account key on each certificate and has no rows here.
class AcmeAccount < Sequel::Model
  many_to_one :acme_provider

  plugin ResourceMethods, etc_type: true, encrypted_columns: [:account_key]

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
