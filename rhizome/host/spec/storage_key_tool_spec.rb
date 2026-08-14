# frozen_string_literal: true

require_relative "../lib/storage_key_tool"
require_relative "../lib/storage_key_encryption"
require "base64"
require "json"
require "tmpdir"
require "securerandom"
require "fileutils"

# Real end-to-end crypto round-trips (no mocking of the encryption): wrap a
# known DEK with an "old" KEK, rotate to a "new" KEK through the tool, and
# assert the DEK is preserved and now only opens with the new KEK. The negative
# paths use genuinely divergent files too.
RSpec.describe StorageKeyTool do
  let(:dir) { Dir.mktmpdir }
  let(:old_kek) { make_kek }
  let(:new_kek) { make_kek }
  let(:dek_key) { SecureRandom.random_bytes(32) }
  let(:dek_key2) { SecureRandom.random_bytes(32) }
  let(:spdk_file) { File.join(dir, "data_encryption_key.json") }

  after do
    FileUtils.rm_rf(dir)
  end

  def make_kek(key = SecureRandom.random_bytes(32))
    {
      "algorithm" => "aes-256-gcm",
      "key" => Base64.strict_encode64(key),
      "init_vector" => Base64.strict_encode64(SecureRandom.random_bytes(12)),
      "auth_data" => "Ubicloud-Storage-Auth",
    }
  end

  before do
    allow_any_instance_of(StoragePath).to receive(:storage_dir).and_return(dir)
    allow_any_instance_of(StoragePath).to receive(:data_encryption_key).and_return(spdk_file)
  end

  # The version selects the backend format; empty string is an SPDK volume.
  def tool(version)
    StorageKeyTool.new("vm12345", "nvme0", 0, version)
  end

  def read_dek(t, kek)
    t.send(:read_dek, t.key_file, kek)
  end

  # Reproduces exactly what StorageVolume writes for the SPDK backend.
  def write_spdk(file, kek, cipher:, key:, key2:)
    StorageKeyEncryption.new(kek).write_encrypted_dek(file, {cipher: cipher, key: key, key2: key2})
  end

  # Every backend follows the same rotation flow; only the input file differs.
  shared_examples "rotates the KEK, preserving the DEK" do
    it "reencrypts to a .new sidecar, verifies, retires, and preserves the DEK" do
      t = tool(version)

      t.reencrypt_key_file(old_kek, new_kek)
      expect(File.exist?("#{t.key_file}.new")).to be(true)

      expect { t.test_keys(old_kek, new_kek) }.not_to raise_error

      t.retire_old_key
      expect(File.exist?("#{t.key_file}.new")).to be(false)

      # After retire, the live file is wrapped with the new KEK and unwraps to
      # the original DEK...
      dek = read_dek(tool(version), new_kek)
      expect(dek[:key]).to eq(dek_key)
      expect(dek[:key2]).to eq(dek_key2)

      # ...and no longer opens with the old KEK.
      expect { read_dek(tool(version), old_kek) }.to raise_error(OpenSSL::Cipher::CipherError)
    end
  end

  context "with an spdk volume (data_encryption_key.json)" do
    let(:version) { "" }

    before { write_spdk(spdk_file, old_kek, cipher: "AES_XTS", key: dek_key, key2: dek_key2) }

    it_behaves_like "rotates the KEK, preserving the DEK"

    it "leaves the spdk key file in place (it is the rotation target)" do
      tool("").reencrypt_key_file(old_kek, new_kek)
      expect(File.exist?(spdk_file)).to be(true)
    end
  end

  # Drive test_keys mismatches with real files/crypto (not by stubbing read_dek):
  # write a genuinely divergent .new sidecar and assert each branch raises.
  describe "#test_keys mismatch detection" do
    before { write_spdk(spdk_file, old_kek, cipher: "AES_XTS", key: dek_key, key2: dek_key2) }

    it "raises when the cipher differs" do
      write_spdk("#{spdk_file}.new", new_kek, cipher: "AES_CBC", key: dek_key, key2: dek_key2)
      expect { tool("").test_keys(old_kek, new_kek) }.to raise_error("ciphers don't match")
    end

    it "raises when the first key differs" do
      write_spdk("#{spdk_file}.new", new_kek, cipher: "AES_XTS", key: SecureRandom.random_bytes(32), key2: dek_key2)
      expect { tool("").test_keys(old_kek, new_kek) }.to raise_error("keys don't match")
    end

    it "raises when the second key differs" do
      write_spdk("#{spdk_file}.new", new_kek, cipher: "AES_XTS", key: dek_key, key2: SecureRandom.random_bytes(32))
      expect { tool("").test_keys(old_kek, new_kek) }.to raise_error("second keys don't match")
    end
  end
end
