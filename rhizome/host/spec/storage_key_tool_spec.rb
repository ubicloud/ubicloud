# frozen_string_literal: true

require_relative "../lib/storage_key_tool"
require "openssl"
require "base64"

RSpec.describe StorageKeyTool do
  subject(:skt) { described_class.new("vm12345", DEFAULT_STORAGE_DEVICE, 3) }

  def generate_kek
    key_wrapping_algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(key_wrapping_algorithm)
    {
      algorithm: key_wrapping_algorithm,
      key: cipher.random_key,
      init_vector: cipher.random_iv,
      auth_data: "Ubicloud-Storage-Auth"
    }
  end

  def key_file
    "/var/storage/vm12345/3/data_encryption_key.json"
  end

  def new_key_file
    "#{key_file}.new"
  end

  def register_ro_storage_key_encryption(kek, key_file, cipher, key, key2)
    ske = instance_double(StorageKeyEncryption)
    expect(ske).to receive(:read_encrypted_dek).with(key_file).and_return({
      cipher: cipher,
      key: key,
      key2: key2
    })
    expect(StorageKeyEncryption).to receive(:new).with(kek).and_return(ske)
  end

  def register_wo_storage_key_encryption(kek, key_file, cipher, key, key2)
    ske = instance_double(StorageKeyEncryption)
    expect(ske).to receive(:write_encrypted_dek).with(key_file, {
      cipher: cipher,
      key: key,
      key2: key2
    })
    expect(StorageKeyEncryption).to receive(:new).with(kek).and_return(ske)
  end

  it "can reencrypt key file" do
    old_key = generate_kek
    new_key = generate_kek

    register_ro_storage_key_encryption(old_key, key_file, "cipher", "key", "key2")
    register_wo_storage_key_encryption(new_key, new_key_file, "cipher", "key", "key2")

    expect(skt.reencrypt_key_file(old_key, new_key)).to be_nil
  end

  describe "#test_keys" do
    it "raises error if ciphers don't match" do
      old_key = generate_kek
      new_key = generate_kek

      register_ro_storage_key_encryption(old_key, key_file, "cipher_1", "key", "key2")
      register_ro_storage_key_encryption(new_key, new_key_file, "cipher_2", "key", "key2")

      expect {
        skt.test_keys(old_key, new_key)
      }.to raise_error RuntimeError, "ciphers don't match"
    end

    it "raises error if keys don't match" do
      old_key = generate_kek
      new_key = generate_kek

      register_ro_storage_key_encryption(old_key, key_file, "cipher", "key_1", "key2")
      register_ro_storage_key_encryption(new_key, new_key_file, "cipher", "key_2", "key2")

      expect {
        skt.test_keys(old_key, new_key)
      }.to raise_error RuntimeError, "keys don't match"
    end

    it "raises error if second keys don't match" do
      old_key = generate_kek
      new_key = generate_kek

      register_ro_storage_key_encryption(old_key, key_file, "cipher", "key", "key2_1")
      register_ro_storage_key_encryption(new_key, new_key_file, "cipher", "key", "key2_2")

      expect {
        skt.test_keys(old_key, new_key)
      }.to raise_error RuntimeError, "second keys don't match"
    end

    it "can test keys" do
      old_key = generate_kek
      new_key = generate_kek

      register_ro_storage_key_encryption(old_key, key_file, "cipher", "key", "key2")
      register_ro_storage_key_encryption(new_key, new_key_file, "cipher", "key", "key2")

      expect(skt.test_keys(old_key, new_key)).to be_nil
    end
  end

  it "can retire old key" do
    expect(File).to receive(:rename).with(new_key_file, key_file)

    f = instance_double(File)
    expect(File).to receive(:open).with("/var/storage/vm12345/3").and_return(f)

    skt.retire_old_key
  end
end
