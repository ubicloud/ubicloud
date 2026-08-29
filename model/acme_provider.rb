# frozen_string_literal: true

require_relative "../model"

class AcmeProvider < Sequel::Model
  plugin ResourceMethods, etc_type: true, encrypted_columns: [:key]

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
