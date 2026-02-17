# frozen_string_literal: true

require_relative "../../common/lib/util"
require "openssl"
require "base64"
require "securerandom"

class StorageKeyEncryption
  def initialize(key_encryption_cipher)
    @key_encryption_cipher = key_encryption_cipher
  end

  # Wrap a plaintext with AES-256-GCM using the v2 format:
  # [12-byte nonce || ciphertext || 16-byte tag]
  # AAD is the secret name.
  def self.aes256gcm_encrypt(kek_bytes, aad, plaintext)
    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.encrypt
    cipher.key = kek_bytes
    nonce = SecureRandom.random_bytes(12)
    cipher.iv = nonce
    cipher.auth_data = aad
    ciphertext = cipher.update(plaintext) + cipher.final
    tag = cipher.auth_tag
    nonce + ciphertext + tag
  end

  # Return the raw 32-byte KEK for v2 pipe delivery.
  def kek_bytes
    Base64.decode64(@key_encryption_cipher["key"])
  end

  # Generate v2 encryption TOML section.
  def v2_encryption_toml
    lines = ["[encryption]"]
    lines << 'xts_key.ref = "xts-key"'
    lines.join("\n") + "\n"
  end

  # Generate v2 secrets TOML section.
  def v2_secrets_toml(encryption_key, kek_pipe)
    # Combine the two 32-byte key halves into a single 64-byte XTS key
    key1_bytes = [encryption_key[:key]].pack("H*")
    key2_bytes = [encryption_key[:key2]].pack("H*")
    xts_plaintext = key1_bytes + key2_bytes

    # Encrypt using v2 format: [nonce || ciphertext || tag] with secret name as AAD
    wrapped_xts = self.class.aes256gcm_encrypt(kek_bytes, "xts-key", xts_plaintext)
    wrapped_xts_b64 = Base64.strict_encode64(wrapped_xts)

    lines = []

    # The XTS key secret: inline base64-encoded ciphertext, decrypted by kek
    lines << "[secrets.xts-key]"
    lines << "source.inline = #{toml_str(wrapped_xts_b64)}"
    lines << 'encoding = "base64"'
    lines << 'encrypted_by.ref = "kek"'
    lines << ""

    # The KEK secret: read from a named pipe at runtime
    lines << "[secrets.kek]"
    lines << "source.file = #{toml_str(kek_pipe)}"
    lines << 'encoding = "base64"'
    lines.join("\n") + "\n"
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

  def toml_str(value)
    "\"#{value.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"")}\""
  end
end
