# frozen_string_literal: true

require_relative "../model"

class LockedDomain < Sequel::Model
  unrestrict_primary_key
  many_to_one :oidc_provider
end

# Table: locked_domain
# Columns:
#  domain           | citext | PRIMARY KEY
#  oidc_provider_id | uuid   | NOT NULL
# Indexes:
#  locked_domain_pkey | PRIMARY KEY btree (domain)
# Foreign key constraints:
#  locked_domain_oidc_provider_id_fkey | (oidc_provider_id) REFERENCES oidc_provider(id)
