# frozen_string_literal: true

require "openssl"
require "securerandom"
require "argon2/kdf"

NONCE_LEN = 8
SALT_LEN = 32

class Minio::Crypto
  class AesGcmCipherProvider
    def self.get_cipher(key, nonce, encrypt: false)
      OpenSSL::Cipher.new("aes-256-gcm").tap do |cipher|
        if encrypt
          cipher.encrypt
        else
          cipher.decrypt
        end
        cipher.key = key
        cipher.iv = nonce
      end
    end
  end

  def encrypt(payload, password)
    # Generate nonce and salt
    nonce = SecureRandom.random_bytes(NONCE_LEN)
    salt = SecureRandom.random_bytes(SALT_LEN)

    # Generate the key using Argon2
    key = generate_key(password, salt)

    # Prepare the padded nonce
    padded_nonce = Array.new(NONCE_LEN + 4, 0)
    nonce.bytes.each_with_index { |byte, index| padded_nonce[index] = byte }

    # Select cipher provider and create cipher
    cipher_provider = AesGcmCipherProvider

    # Generate additional data
    add_data = generate_additional_data(cipher_provider, key, padded_nonce.pack("C*"))

    padded_nonce[8] = 1
    cipher = cipher_provider.get_cipher(key, padded_nonce.pack("C*"), encrypt: true)
    cipher.auth_data = add_data

    # Encrypt the payload
    encrypted_data = cipher.update(payload) + cipher.final
    mac = cipher.auth_tag

    # Construct the final encrypted payload
    salt + [0].pack("C") + nonce + encrypted_data + mac
  end

  def decrypt(payload, password)
    pos = 0
    salt = payload.byteslice(pos, SALT_LEN)
    pos += SALT_LEN

    cipher_id = payload.byteslice(pos).ord
    pos += 1

    raise "Unsupported cipher ID: #{cipher_id}" unless cipher_id.zero?

    cipher_provider = AesGcmCipherProvider

    nonce = payload.byteslice(pos, NONCE_LEN)

    pos += NONCE_LEN

    encrypted_data = payload.byteslice(pos...-16)
    hmac_tag = payload.byteslice(-16, 16)

    key = generate_key(password, salt)

    # looks like NONCE should have 12 bytes but MinIO uses 8 bytes
    padded_nonce = Array.new(12, 0)
    nonce.bytes.each_with_index { |byte, index| padded_nonce[index] = byte }
    add_data = generate_additional_data(cipher_provider, key, padded_nonce.pack("C*"))
    padded_nonce[8] = 1

    cipher = cipher_provider.get_cipher(key, padded_nonce.pack("C*"))
    cipher.auth_tag = hmac_tag
    cipher.auth_data = add_data

    cipher.update(encrypted_data) + cipher.final
  end

  def generate_key(password, salt)
    Argon2::KDF.argon2id(password.encode, salt: salt, t: 1, m: 16, p: 4, length: 32)
  end

  def generate_additional_data(cipher_provider, key, padded_nonce)
    # Initialize the cipher with the provided key and nonce
    cipher = cipher_provider.get_cipher(key, padded_nonce, encrypt: true)

    # In Ruby, for AES-GCM, the tag is generated after finalizing the encryption
    # For this function, we'll perform a dummy encryption to generate the tag
    cipher.auth_data = ""
    cipher.update("") << cipher.final

    # Construct the new tag array
    new_tag = [0x80] + cipher.auth_tag.bytes

    # Return the new tag array as a byte string
    new_tag.pack("C*")
  end
end
