# frozen_string_literal: true

require_relative "../lib/storage_key_tool"
require_relative "../lib/storage_key_encryption"
require_relative "../lib/storage_volume"
require "yaml"
require "base64"
require "json"
require "tmpdir"
require "securerandom"
require "fileutils"

# Real end-to-end crypto round-trips (no mocking of the encryption): for each of
# the three on-host backends, wrap a known DEK with an "old" KEK, rotate to a
# "new" KEK through the tool, and assert the DEK is preserved and now only opens
# with the new KEK. The negative paths use genuinely divergent files too.
RSpec.describe StorageKeyTool do
  let(:dir) { Dir.mktmpdir }
  let(:old_kek) { make_kek }
  let(:new_kek) { make_kek }
  let(:dek_key) { SecureRandom.random_bytes(32) }
  let(:dek_key2) { SecureRandom.random_bytes(32) }
  let(:spdk_file) { File.join(dir, "data_encryption_key.json") }
  let(:legacy_file) { File.join(dir, "vhost-backend.conf") }
  let(:v2_file) { File.join(dir, "vhost-backend-secrets.conf") }
  let(:prep_file) { File.join(dir, "prep.json") }

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
    allow_any_instance_of(StoragePath).to receive(:vhost_backend_config).and_return(legacy_file)
    allow_any_instance_of(StoragePath).to receive(:vhost_backend_secrets_config).and_return(v2_file)
    allow_any_instance_of(VmPath).to receive(:prep_json).and_return(prep_file)
  end

  # The version selects the backend format; empty string is an SPDK volume.
  def tool(version)
    StorageKeyTool.new("vm12345", "nvme0", 0, version)
  end

  def read_dek(t, kek)
    t.send(:read_dek, t.key_file, kek)
  end

  # Writers that reproduce exactly what StorageVolume writes for each backend.
  def write_spdk(file, kek, cipher:, key:, key2:)
    StorageKeyEncryption.new(kek).write_encrypted_dek(file, {cipher: cipher, key: key, key2: key2})
  end

  def write_legacy(file, kek, key:, key2:)
    ke = StorageKeyEncryption.new(kek)
    wrap = ->(bytes) { Base64.strict_encode64(ke.wrap_key(bytes).join) }
    File.write(file, {
      "path" => "/var/storage/vm12345/0/disk.raw",
      "encryption_key" => [wrap.call(key), wrap.call(key2)],
    }.to_yaml)
  end

  # A config-v2 secret is base64(nonce || ciphertext || tag); the secret name is
  # both the section suffix and the GCM auth_data.
  def v2_wrap(kek, name, plaintext)
    Base64.strict_encode64(StorageKeyEncryption.aes256gcm_encrypt(Base64.decode64(kek["key"]), name, plaintext))
  end

  # prep.json params for a config-v2 disk-0 volume, with any archive/remote
  # secrets KEK-wrapped exactly as the control plane delivers them.
  def v2_params(kek, archive: false, remote: false)
    params = {"disk_index" => 0, "storage_device" => "nvme0", "device_id" => "vm12345_0",
              "encrypted" => true, "size_gib" => 20, "vhost_block_backend_version" => "v0.4.2"}
    if archive
      params["archive_source"] = {
        "bucket" => "ubicloud-images", "prefix" => "p", "region" => "auto",
        "endpoint" => "https://example.r2.cloudflarestorage.com", "autofetch" => true,
        "encrypted_access_key_id" => v2_wrap(kek, "archive-access-key", access_key),
        "encrypted_secret_access_key" => v2_wrap(kek, "archive-secret-key", secret_key),
        "encrypted_archive_kek" => v2_wrap(kek, "archive-kek", archive_kek),
      }
    end
    if remote
      params["remote_source"] = {
        "address" => "10.0.0.1:9999", "psk_identity" => "id", "autofetch" => true,
        "disk_size_bytes" => 21474836480,
        "encrypted_psk" => v2_wrap(kek, "remote-psk", psk_plaintext),
      }
    end
    params
  end

  # Write the config-v2 secrets file with the real producer so the test can't
  # drift from what StorageVolume writes.
  def write_v2(file, kek, params)
    encryption_key = {key: dek_key.unpack1("H*"), key2: dek_key2.unpack1("H*")}
    File.write(file, StorageVolume.new("vm12345", params).v2_secrets_toml(encryption_key, kek))
  end

  def write_prep(volumes)
    File.write(prep_file, JSON.generate({"storage_volumes" => volumes}))
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

    before { write_spdk(spdk_file, old_kek, cipher: StorageKeyTool::XTS_CIPHER, key: dek_key, key2: dek_key2) }

    it_behaves_like "rotates the KEK, preserving the DEK"

    it "leaves the spdk key file in place (it is the rotation target)" do
      tool("").reencrypt_key_file(old_kek, new_kek)
      expect(File.exist?(spdk_file)).to be(true)
    end
  end

  context "with a legacy ubiblk volume (vhost-backend.conf YAML)" do
    let(:version) { "v0.3.1" }

    before { write_legacy(legacy_file, old_kek, key: dek_key, key2: dek_key2) }

    it_behaves_like "rotates the KEK, preserving the DEK"
  end

  context "with a config-v2 ubiblk volume (vhost-backend-secrets.conf TOML)" do
    let(:version) { "v0.4.2" }
    let(:v2_volume) { v2_params(old_kek) }

    before do
      write_v2(v2_file, old_kek, v2_volume)
      write_prep([{"disk_index" => 1}, v2_volume])
    end

    it_behaves_like "rotates the KEK, preserving the DEK"

    it "regenerates a producer-shaped secrets file with the kek reference" do
      t = tool(version)
      t.reencrypt_key_file(old_kek, new_kek)
      new_text = File.read("#{t.key_file}.new")
      expect(new_text).to include("[secrets.xts-key]")
      expect(new_text).to include("[secrets.kek]")
      expect(new_text).to include("encrypted_by.ref = \"kek\"")
    end
  end

  context "with a config-v2 volume that has an archive source" do
    let(:version) { "v0.4.2" }
    let(:access_key) { "AKIAEXAMPLEACCESSKEY" }
    let(:secret_key) { "example/secret/access/key/value" }
    let(:archive_kek) { SecureRandom.random_bytes(32) }
    let(:v2_volume) { v2_params(old_kek, archive: true) }

    before do
      write_v2(v2_file, old_kek, v2_volume)
      write_prep([v2_volume])
    end

    it "re-wraps every archive secret with the new KEK, preserving the plaintexts" do
      t = tool(version)
      t.reencrypt_key_file(old_kek, new_kek)
      new_text = File.read("#{t.key_file}.new")
      new_bytes = Base64.decode64(new_kek["key"])

      {
        "secrets.archive-access-key" => ["archive-access-key", access_key],
        "secrets.archive-secret-key" => ["archive-secret-key", secret_key],
        "secrets.archive-kek" => ["archive-kek", archive_kek],
      }.each do |section, (name, plaintext)|
        wrapped = Base64.decode64(t.send(:v2_inline, new_text, section))
        expect(StorageKeyEncryption.aes256gcm_decrypt(new_bytes, name, wrapped)).to eq(plaintext)
      end

      # The old KEK can no longer open the re-wrapped archive secrets.
      old_bytes = Base64.decode64(old_kek["key"])
      wrapped = Base64.decode64(t.send(:v2_inline, new_text, "secrets.archive-access-key"))
      expect {
        StorageKeyEncryption.aes256gcm_decrypt(old_bytes, "archive-access-key", wrapped)
      }.to raise_error(OpenSSL::Cipher::CipherError)
    end
  end

  context "with a config-v2 volume that has a remote source" do
    let(:version) { "v0.4.2" }
    let(:psk_plaintext) { SecureRandom.random_bytes(32) }
    let(:v2_volume) { v2_params(old_kek, remote: true) }

    before do
      write_v2(v2_file, old_kek, v2_volume)
      write_prep([v2_volume])
    end

    it_behaves_like "rotates the KEK, preserving the DEK"

    it "re-wraps the remote-psk secret with the new KEK, preserving the plaintext" do
      t = tool(version)
      t.reencrypt_key_file(old_kek, new_kek)
      new_text = File.read("#{t.key_file}.new")

      wrapped = Base64.decode64(t.send(:v2_inline, new_text, "secrets.remote-psk"))
      expect(StorageKeyEncryption.aes256gcm_decrypt(Base64.decode64(new_kek["key"]), "remote-psk", wrapped)).to eq(psk_plaintext)

      # The old KEK can no longer open the re-wrapped secret.
      expect {
        StorageKeyEncryption.aes256gcm_decrypt(Base64.decode64(old_kek["key"]), "remote-psk", wrapped)
      }.to raise_error(OpenSSL::Cipher::CipherError)
    end
  end

  describe "stale spdk key file removal" do
    # The SPDK->ubiblk migration leaves a stale data_encryption_key.json behind;
    # rotation removes it for vhost backends so it can't linger as an out-of-date
    # copy of the key.
    it "removes the stale spdk key file when rotating a legacy volume" do
      write_legacy(legacy_file, old_kek, key: dek_key, key2: dek_key2)
      write_spdk(spdk_file, old_kek, cipher: StorageKeyTool::XTS_CIPHER, key: dek_key, key2: dek_key2)
      tool("v0.3.1").reencrypt_key_file(old_kek, new_kek)
      expect(File.exist?(spdk_file)).to be(false)
    end

    it "removes the stale spdk key file when rotating a config-v2 volume" do
      v2_volume = v2_params(old_kek)
      write_v2(v2_file, old_kek, v2_volume)
      write_spdk(spdk_file, old_kek, cipher: StorageKeyTool::XTS_CIPHER, key: dek_key, key2: dek_key2)
      write_prep([v2_volume])
      tool("v0.4.2").reencrypt_key_file(old_kek, new_kek)
      expect(File.exist?(spdk_file)).to be(false)
    end
  end

  # Drive test_keys mismatches with real files/crypto (not by stubbing read_dek):
  # write a genuinely divergent .new sidecar and assert each branch raises.
  describe "#test_keys mismatch detection" do
    before { write_spdk(spdk_file, old_kek, cipher: StorageKeyTool::XTS_CIPHER, key: dek_key, key2: dek_key2) }

    it "raises when the cipher differs" do
      write_spdk("#{spdk_file}.new", new_kek, cipher: "AES_CBC", key: dek_key, key2: dek_key2)
      expect { tool("").test_keys(old_kek, new_kek) }.to raise_error("ciphers don't match")
    end

    it "raises when the first key differs" do
      write_spdk("#{spdk_file}.new", new_kek, cipher: StorageKeyTool::XTS_CIPHER, key: SecureRandom.random_bytes(32), key2: dek_key2)
      expect { tool("").test_keys(old_kek, new_kek) }.to raise_error("keys don't match")
    end

    it "raises when the second key differs" do
      write_spdk("#{spdk_file}.new", new_kek, cipher: StorageKeyTool::XTS_CIPHER, key: dek_key, key2: SecureRandom.random_bytes(32))
      expect { tool("").test_keys(old_kek, new_kek) }.to raise_error("second keys don't match")
    end
  end

  describe "config-v2 rewrite errors" do
    it "fails to read when the [secrets.xts-key] section is missing" do
      File.write(v2_file, "[secrets.kek]\nsource.file = \"/x/kek.pipe\"\n")
      t = tool("v0.4.2")
      expect { read_dek(t, old_kek) }.to raise_error(/no \[secrets\.xts-key\] source\.inline/)
    end

    it "fails when prep.json has no matching disk_index" do
      write_v2(v2_file, old_kek, v2_params(old_kek))
      write_prep([{"disk_index" => 9}])
      expect { tool("v0.4.2").reencrypt_key_file(old_kek, new_kek) }.to raise_error(/no storage volume with disk_index 0/)
    end
  end
end
