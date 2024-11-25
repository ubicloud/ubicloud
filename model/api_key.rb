# frozen_string_literal: true

require_relative "../model"

class ApiKey < Sequel::Model
  include ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :key
  end

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def self.create_with_id(owner_table:, owner_id:, used_for:)
    unless %w[project inference_endpoint accounts].include?(owner_table.to_s)
      fail "Invalid owner_table: #{owner_table}"
    end

    key = SecureRandom.alphanumeric(32)
    super(owner_table:, owner_id:, key:, used_for:)
  end

  def rotate
    new_key = SecureRandom.alphanumeric(32)
    update(key: new_key, updated_at: Time.now)
  end
end

# Table: api_key
# Columns:
#  id          | uuid                     | PRIMARY KEY
#  created_at  | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at  | timestamp with time zone | NOT NULL DEFAULT now()
#  owner_table | text                     | NOT NULL
#  owner_id    | uuid                     | NOT NULL
#  used_for    | text                     | NOT NULL
#  key         | text                     | NOT NULL
#  is_valid    | boolean                  | NOT NULL DEFAULT true
# Indexes:
#  api_key_pkey                       | PRIMARY KEY btree (id)
#  api_key_owner_table_owner_id_index | btree (owner_table, owner_id)
