# frozen_string_literal: true

require_relative "../model"

require "bcrypt"

class ApiKeyPair < Sequel::Model
  include ResourceMethods

  plugin :column_encryption do |enc|
    enc.column :key1
    enc.column :key2
  end

  def self.ubid_type
    UBID::TYPE_ETC
  end

  def self.create_with_id(owner_table:, owner_id:)
    unless ["project", "inference_endpoint"].include?(owner_table)
      fail "Invalid owner_table: #{owner_table}"
    end

    key1 = SecureRandom.alphanumeric(32)
    key2 = SecureRandom.alphanumeric(32)
    super(owner_table: owner_table, owner_id: owner_id, key1: key1, key1_hash: BCrypt::Password.create(key1), key2: key2, key2_hash: BCrypt::Password.create(key2))
  end

  def rotate
    new_key = SecureRandom.alphanumeric(32)
    update(key1: key2, key1_hash: key2_hash, key2: new_key, key2_hash: BCrypt::Password.create(new_key))
  end
end
