# frozen_string_literal: true

require_relative "../lib/storage_key_encryption"
require "openssl"
require "base64"

RSpec.describe StorageKeyEncryption do
  subject(:sek) {
    algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(algorithm)
    described_class.new({
      "algorithm" => algorithm,
      "key" => Base64.encode64(cipher.random_key),
      "init_vector" => Base64.encode64(cipher.random_iv),
      "auth_data" => "Ubicloud-Test-Auth"
    })
  }

  it "can unwrap a wrapped key" do
    key = "abcdefgh01234567abcdefgh01234567"
    expect(sek.unwrap_key(sek.wrap_key(key))).to eq(key)
  end

  it "can wrap a key" do
    dek = OpenSSL::Cipher.new("aes-256-xts").random_key.unpack1("H*")
    r1 = sek.wrap_key(dek[..63])
    expect(r1[0].length).to eq(64)
    expect(r1[1].length).to eq(16)
    r2 = sek.wrap_key(dek[64..])
    expect(r2[0].length).to eq(64)
    expect(r2[1].length).to eq(16)
  end

  it "fails if algorithm is not aes-256-gcm" do
    sek2 = described_class.new({
      "algorithm" => "aes256-wrap",
      :key => "123",
      :init_vector => "456"
    })

    expect {
      sek2.unwrap_key("some key")
    }.to raise_error RuntimeError, "currently only aes-256-gcm is supported"

    expect {
      sek2.wrap_key("some key")
    }.to raise_error RuntimeError, "currently only aes-256-gcm is supported"
  end

  it "fails if auth_tag is not 16" do
    key = "abcdefgh01234567abcdefgh01234567"
    wrapped = sek.wrap_key(key)
    wrapped[1] = wrapped[1][0]

    expect {
      sek.unwrap_key(wrapped)
    }.to raise_error RuntimeError, "Invalid auth_tag size: 1"
  end
end
