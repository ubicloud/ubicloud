# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe StorageKeyEncryptionKey do
  describe ".create_random" do
    it "generates an aes-256-gcm random KEK by default" do
      kek = described_class.create_random(auth_data: "some_auth_data")
      expect(kek.algorithm).to eq("aes-256-gcm")
      expect(Base64.strict_decode64(kek.key).bytesize).to eq(32)
      expect(Base64.strict_decode64(kek.init_vector).bytesize).to eq(12)
      expect(kek.auth_data).to eq("some_auth_data")
    end

    it "generates a random KEK with the specified algorithm" do
      kek = described_class.create_random(auth_data: "some_auth_data", algorithm: "aes-128-gcm")
      expect(kek.algorithm).to eq("aes-128-gcm")
      expect(Base64.strict_decode64(kek.key).bytesize).to eq(16)
      expect(Base64.strict_decode64(kek.init_vector).bytesize).to eq(12)
      expect(kek.auth_data).to eq("some_auth_data")
    end
  end

  describe "#encrypt" do
    def decrypt(key, ciphertext_b64, auth_data)
      ciphertext = Base64.strict_decode64(ciphertext_b64)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = Base64.decode64(key)
      cipher.iv = ciphertext[0...12]
      cipher.auth_data = auth_data
      cipher.auth_tag = ciphertext[-16..]
      cipher.update(ciphertext[12...-16]) << cipher.final
    end

    it "encrypts and decrypts correctly" do
      kek = described_class.create_random(auth_data: "unused_auth_data")

      auth_data_1 = "test_auth_data"
      plaintext_1 = "This is a secret message."
      ciphertext_1 = kek.encrypt(plaintext_1, auth_data_1)
      expect(decrypt(kek.key, ciphertext_1, auth_data_1)).to eq(plaintext_1)

      auth_data_2 = "another_auth_data"
      plaintext_2 = "Another secret message."
      ciphertext_2 = kek.encrypt(plaintext_2, auth_data_2)
      expect(decrypt(kek.key, ciphertext_2, auth_data_2)).to eq(plaintext_2)

      iv_1 = Base64.strict_decode64(ciphertext_1)[0...12]
      iv_2 = Base64.strict_decode64(ciphertext_2)[0...12]
      expect(iv_1).not_to eq(iv_2)
    end

    it "raises an error if key is used with the wrong auth_data" do
      kek = described_class.create_random(auth_data: "unused_auth_data")
      ciphertext = kek.encrypt("secret message", "correct_auth_data")
      expect {
        decrypt(kek.key, ciphertext, "wrong_auth_data")
      }.to raise_error(OpenSSL::Cipher::CipherError)
    end

    it "raises an error if the algorithm is not supported" do
      kek = described_class.create_random(auth_data: "test_auth_data", algorithm: "aes-128-cbc")
      expect {
        kek.encrypt("plaintext", "test_auth_data")
      }.to raise_error RuntimeError, "currently only aes-256-gcm is supported"
    end
  end
end
