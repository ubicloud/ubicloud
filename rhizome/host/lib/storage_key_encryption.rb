# frozen_string_literal: true

require_relative "../../common/lib/util"
require "openssl"
require "base64"

class StorageKeyEncryption
  def initialize(key_encryption_cipher)
    @key_encryption_cipher = key_encryption_cipher
  end

  def write_encrypted_dek(key_file, data_encryption_key)
    File.open(key_file, "w") {
      wrapped_key1 = wrap_key(data_encryption_key[:key])
      wrapped_key2 = wrap_key(data_encryption_key[:key2])
      wrapped_key1_b64 = wrapped_key1.map { |s| Base64.strict_encode64(s) }
      wrapped_key2_b64 = wrapped_key2.map { |s| Base64.strict_encode64(s) }
      _1.write(JSON.pretty_generate({
        cipher: data_encryption_key[:cipher],
        key: wrapped_key1_b64,
        key2: wrapped_key2_b64
      }))
      fsync_or_fail(_1)
    }
  end

  def read_encrypted_dek(key_file)
    data_encryption_key = JSON.parse(File.read(key_file))
    wrapped_key1_b64 = data_encryption_key["key"]
    wrapped_key2_b64 = data_encryption_key["key2"]
    wrapped_key1 = wrapped_key1_b64.map { |s| Base64.decode64(s) }
    wrapped_key2 = wrapped_key2_b64.map { |s| Base64.decode64(s) }
    {
      cipher: data_encryption_key["cipher"],
      key: unwrap_key(wrapped_key1),
      key2: unwrap_key(wrapped_key2)
    }
  end

  def wrap_key(key)
    algorithm = @key_encryption_cipher["algorithm"]
    fail "currently only aes-256-gcm is supported" unless algorithm == "aes-256-gcm"

    cipher = OpenSSL::Cipher.new(algorithm)
    cipher.encrypt
    cipher.key = Base64.decode64(@key_encryption_cipher["key"])
    cipher.iv = Base64.decode64(@key_encryption_cipher["init_vector"])
    cipher.auth_data = @key_encryption_cipher["auth_data"]
    [
      cipher.update(key) + cipher.final,
      cipher.auth_tag
    ]
  end

  def unwrap_key(encrypted_key)
    algorithm = @key_encryption_cipher["algorithm"]
    fail "currently only aes-256-gcm is supported" unless algorithm == "aes-256-gcm"

    decipher = OpenSSL::Cipher.new(algorithm)
    decipher.decrypt
    decipher.key = Base64.decode64(@key_encryption_cipher["key"])
    decipher.iv = Base64.decode64(@key_encryption_cipher["init_vector"])
    decipher.auth_data = @key_encryption_cipher["auth_data"]

    auth_tag = encrypted_key[1]

    # We reject if auth_tag length is not the spec maximum (16), see
    # https://github.com/ruby/openssl/issues/63 for more details.
    fail "Invalid auth_tag size: #{auth_tag.bytesize}" unless auth_tag.bytesize == 16

    decipher.auth_tag = auth_tag
    decipher.update(encrypted_key[0]) + decipher.final
  end
end
