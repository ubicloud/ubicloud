# frozen_string_literal: true

require_relative "../model"

class Secret < Sequel::Model
  many_to_one :secret_store

  # Values are encrypted at rest; keys are stored in plaintext since they are
  # used to look up secrets.
  plugin ResourceMethods, encrypted_columns: :value

  # Keys must start with a letter or number, may contain letters, numbers,
  # hyphens, underscores, and dots, and are at most 255 characters long.
  KEY_PATTERN = %r{\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,254}\z}

  def validate
    super
    validates_presence [:key, :value]
    validates_format(KEY_PATTERN, :key, message: "must start with a letter or number and only contain letters, numbers, hyphens, underscores, and dots (max length 255).", allow_nil: true)
  end
end

# Table: secret
# Columns:
#  id              | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(814)
#  secret_store_id | uuid                     | NOT NULL
#  key             | text                     | NOT NULL
#  value           | text                     | NOT NULL
#  created_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  updated_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  secret_pkey                      | PRIMARY KEY btree (id)
#  secret_secret_store_id_key_index | UNIQUE btree (secret_store_id, key)
# Foreign key constraints:
#  secret_secret_store_id_fkey | (secret_store_id) REFERENCES secret_store(id)
