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

    key1 = generate_new_key
    key2 = generate_new_key
    super(owner_table: owner_table, owner_id: owner_id, key1: key1, key1_hash: generate_hash(key1), key2: key2, key2_hash: generate_hash(key2))
  end

  def generate_new_key
    SecureRandom.alphanumeric(32)
  end

  def generate_hash(key)
    BCrypt::Password.create(key)
  end

  def rotate_key1
    new_key = generate_new_key
    update(key1: new_key, key1_hash: generate_hash(new_key))
  end

  def rotate_key2
    new_key = generate_new_key
    update(key2: new_key, key2_hash: generate_hash(new_key))
  end
end
