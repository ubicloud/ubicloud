# frozen_string_literal: true

require "openssl"
require "base64"
require_relative "../model"

class StorageKeyEncryptionKey < Sequel::Model
  plugin ResourceMethods, encrypted_columns: [:key, :init_vector]

  def self.create_random(auth_data:, algorithm: "aes-256-gcm")
    cipher = OpenSSL::Cipher.new(algorithm)
    key = cipher.random_key
    init_vector = cipher.random_iv
    create(
      algorithm:,
      key: Base64.strict_encode64(key),
      init_vector: Base64.strict_encode64(init_vector),
      auth_data:,
    )
  end

  # Wrap a plaintext with AES-256-GCM:
  # [12-byte nonce || ciphertext || 16-byte tag]
  # This is used to create an encrypted DEK that is stored in Ubiblk config v2.
  #
  # The nonce (IV) must be unique per key; we generate a random 12-byte nonce
  # for each encryption.
  #
  # `auth_data` is additional authenticated data (AAD). It is not encrypted,
  # but must be provided unchanged during decryption or authentication fails.
  # Ubiblk config v2 uses the key name as AAD.
  def encrypt(plaintext, auth_data)
    fail "currently only aes-256-gcm is supported" unless algorithm == "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(algorithm)
    cipher.encrypt
    cipher.key = Base64.decode64(key)
    init_vector = cipher.random_iv
    cipher.iv = init_vector
    cipher.auth_data = auth_data
    Base64.strict_encode64(init_vector << cipher.update(plaintext) << cipher.final << cipher.auth_tag)
  end

  def secret_key_material_hash
    # default to_hash doesn't decrypt encrypted columns, so implement
    # this to decrypt keys when they need to be sent to a running copy
    # of spdk.
    {
      "key" => key,
      "init_vector" => init_vector,
      "algorithm" => algorithm,
      "auth_data" => auth_data,
    }
  end
end

# Table: storage_key_encryption_key
# Columns:
#  id          | uuid                     | PRIMARY KEY
#  algorithm   | text                     | NOT NULL
#  key         | text                     | NOT NULL
#  init_vector | text                     | NOT NULL
#  auth_data   | text                     | NOT NULL
#  created_at  | timestamp with time zone | NOT NULL DEFAULT now()
# Indexes:
#  storage_key_encryption_key_pkey | PRIMARY KEY btree (id)
# Referenced By:
#  machine_image_version_metal | machine_image_version_metal_archive_kek_id_fkey | (archive_kek_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume           | vm_storage_volume_key_encryption_key_1_id_fkey  | (key_encryption_key_1_id) REFERENCES storage_key_encryption_key(id)
#  vm_storage_volume           | vm_storage_volume_key_encryption_key_2_id_fkey  | (key_encryption_key_2_id) REFERENCES storage_key_encryption_key(id)
