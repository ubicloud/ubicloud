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
      it.write(JSON.pretty_generate({
        cipher: data_encryption_key[:cipher],
        key: wrap_key(data_encryption_key[:key]),
        key2: wrap_key(data_encryption_key[:key2])
      }))
      fsync_or_fail(it)
    }
  end

  def read_encrypted_dek(key_file)
    data_encryption_key = JSON.parse(File.read(key_file))
    {
      cipher: data_encryption_key["cipher"],
      key: unwrap_key(data_encryption_key["key"]),
      key2: unwrap_key(data_encryption_key["key2"])
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
      Base64.encode64(cipher.update(key) + cipher.final),
      Base64.encode64(cipher.auth_tag)
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

    auth_tag = Base64.decode64(encrypted_key[1])

    # We reject if auth_tag length is not the spec maximum (16), see
    # https://github.com/ruby/openssl/issues/63 for more details.
    fail "Invalid auth_tag size: #{auth_tag.bytesize}" unless auth_tag.bytesize == 16

    decipher.auth_tag = auth_tag
    decipher.update(Base64.decode64(encrypted_key[0])) + decipher.final
  end
end
