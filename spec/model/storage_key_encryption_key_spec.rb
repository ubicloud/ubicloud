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
end
