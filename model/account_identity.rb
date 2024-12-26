# frozen_string_literal: true

require_relative "../model"

class AccountIdentity < Sequel::Model(:account_identities)
  many_to_one :account
end

# Table: account_identities
# Columns:
#  id         | uuid                     | PRIMARY KEY DEFAULT gen_random_uuid()
#  account_id | uuid                     | NOT NULL
#  provider   | text                     | NOT NULL
#  uid        | text                     | NOT NULL
#  created_at | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  account_identities_pkey             | PRIMARY KEY btree (id)
#  account_identities_provider_uid_key | UNIQUE btree (provider, uid)
# Foreign key constraints:
#  account_identities_account_id_fkey | (account_id) REFERENCES accounts(id)
