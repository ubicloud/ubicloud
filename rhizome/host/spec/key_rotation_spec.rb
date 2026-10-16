# frozen_string_literal: true

require_relative "../lib/key_rotation"
require "openssl"
require "base64"
require "securerandom"
require "tmpdir"

RSpec.describe KeyRotation do
  let(:dir) { Dir.mktmpdir }
  let(:user) { "vm12345" }
  let(:old_kek) { make_kek }
  let(:new_kek) { make_kek }
  let(:dek_key) { SecureRandom.random_bytes(32).unpack1("H*") }
  let(:dek_key2) { SecureRandom.random_bytes(32).unpack1("H*") }
  let(:dek) { {cipher: "AES_XTS", key: dek_key, key2: dek_key2} }
  let(:xts_plaintext) { [dek_key].pack("H*") + [dek_key2].pack("H*") }
  let(:spdk_file) { File.join(dir, "data_encryption_key.json") }
  let(:v1_file) { File.join(dir, "vhost-backend.conf") }
  let(:v2_file) { File.join(dir, "vhost-backend-secrets.conf") }
  let(:spdk_rotation) { described_class.new(spdk_file, :spdk, user) }
  let(:v1_rotation) { described_class.new(v1_file, :config_v1, user, stale_spdk_key: spdk_file) }
  let(:v2_rotation) { described_class.new(v2_file, :config_v2, user, stale_spdk_key: spdk_file) }

  after { FileUtils.rm_rf(dir) }

  def make_kek(key = SecureRandom.random_bytes(32))
    {
      "algorithm" => "aes-256-gcm",
      "key" => Base64.strict_encode64(key),
      "init_vector" => Base64.strict_encode64(SecureRandom.random_bytes(12)),
      "auth_data" => "Ubicloud-Storage-Auth",
    }
  end

  # Write each format's on-disk file the way prep does, wrapped with +kek+.
  def write_spdk(kek)
    StorageKeyEncryption.new(kek).write_encrypted_dek(spdk_file, dek)
  end

  def write_v1(kek)
    ke = StorageKeyEncryption.new(kek)
    File.write(v1_file, {"path" => "/d/disk.raw", "encryption_key" => [ke.wrap_key_b64(dek_key), ke.wrap_key_b64(dek_key2)]}.to_yaml)
  end

  def write_v2(kek, secrets = {"xts-key" => xts_plaintext})
    wrapped = secrets.to_h { |name, plaintext| [name, kek_secret(kek, name, plaintext)] }
    wrapped["kek"] = {"source" => {"file" => "/kek.pipe"}, "encoding" => "base64"}
    File.write(v2_file, PerfectTOML.generate({"secrets" => wrapped}))
  end

  def kek_secret(kek, name, plaintext)
    inline = Base64.strict_encode64(StorageKeyEncryption.aes256gcm_encrypt(Base64.decode64(kek["key"]), name, plaintext))
    {"source" => {"inline" => inline}, "encoding" => "base64", "encrypted_by" => {"ref" => "kek"}}
  end

  # Secret files are written 0600 and handed to the VM user; the runner can't chown, so assert the call.
  def expect_chown(path, times: 1)
    expect(FileUtils).to receive(:chown).with(user, user, "#{path}.tmp").exactly(times).times
  end

  # backup then rotate, as the strand does.
  def rotate(rotation)
    expect_chown(rotation.backup_path(old_kek))
    expect_chown("#{rotation.path}.new")
    rotation.backup(old_kek)
    rotation.rotate(old_kek, new_kek)
  end

  # After rotation the live file unwraps under the new KEK to the original secrets, and no longer under the old KEK.
  def expect_rotated(rotation, expected = dek)
    expect(rotation.plaintexts(rotation.path, new_kek)).to eq(expected)
    expect { rotation.plaintexts(rotation.path, old_kek) }.to raise_error(OpenSSL::Cipher::CipherError)
    expect(File.exist?("#{rotation.path}.new")).to be(false)
    expect(File.stat(rotation.path).mode & 0o777).to eq(0o600)
  end

  describe ".build_from_vm" do
    it "rotates an spdk volume's key file" do
      rotation = described_class.build_from_vm("vm12345", {"disk_index" => 0})
      expect(rotation.path).to eq("/var/storage/vm12345/0/data_encryption_key.json")
      expect(rotation.file_format).to eq(:spdk)
      expect(rotation.user).to eq("vm12345")
      expect(rotation.stale_spdk_key).to be_nil
    end

    it "rotates a legacy ubiblk volume's YAML config and clears a leftover spdk key" do
      rotation = described_class.build_from_vm("vm12345", {"disk_index" => 1, "storage_device" => "nvme0", "vhost_block_backend_version" => "v0.3.1"})
      expect(rotation.path).to eq("/var/storage/devices/nvme0/vm12345/1/vhost-backend.conf")
      expect(rotation.file_format).to eq(:config_v1)
      expect(rotation.user).to eq("vm12345")
      expect(rotation.stale_spdk_key).to eq("/var/storage/devices/nvme0/vm12345/1/data_encryption_key.json")
    end

    it "rotates a config-v2 ubiblk volume's secrets file" do
      rotation = described_class.build_from_vm("vm12345", {"disk_index" => 0, "vhost_block_backend_version" => "v0.4.2"})
      expect(rotation.path).to eq("/var/storage/vm12345/0/vhost-backend-secrets.conf")
      expect(rotation.file_format).to eq(:config_v2)
      expect(rotation.stale_spdk_key).to eq("/var/storage/vm12345/0/data_encryption_key.json")
    end
  end

  it "rejects an unknown key file format" do
    expect { described_class.new(spdk_file, :json, user) }.to raise_error("unknown key file format: json")
  end

  describe "#backup" do
    it "copies the live key file byte for byte, 0600 and owned by the VM user" do
      write_spdk(old_kek)
      backup = spdk_rotation.backup_path(old_kek)
      expect_chown(backup)
      spdk_rotation.backup(old_kek)
      expect(File.read(backup)).to eq(File.read(spdk_file))
      expect(File.stat(backup).mode & 0o777).to eq(0o600)
    end
  end

  describe "#rotate" do
    it "rotates an spdk volume" do
      write_spdk(old_kek)
      rotate(spdk_rotation)
      expect_rotated(spdk_rotation)
    end

    it "rotates a legacy ubiblk volume" do
      write_v1(old_kek)
      rotate(v1_rotation)
      expect_rotated(v1_rotation)
    end

    it "rotates a config-v2 volume, re-wrapping every secret" do
      write_v2(old_kek, {"xts-key" => xts_plaintext, "archive-access-key" => "AKIA-secret"})
      rotate(v2_rotation)
      expect_rotated(v2_rotation, {"xts-key" => xts_plaintext, "archive-access-key" => "AKIA-secret"})
    end

    it "removes the stale spdk key file when rotating a migrated ubiblk volume" do
      write_spdk(old_kek) # leftover from before the spdk -> ubiblk migration
      write_v1(old_kek)
      rotate(v1_rotation)
      expect_rotated(v1_rotation)
      expect(File.exist?(spdk_file)).to be(false)
    end

    it "is a safe no-op on retry after a completed rotation (lost ack)" do
      write_v1(old_kek)
      expect_chown(v1_rotation.backup_path(old_kek))
      expect_chown("#{v1_file}.new", times: 2)
      v1_rotation.backup(old_kek)
      v1_rotation.rotate(old_kek, new_kek)
      v1_rotation.rotate(old_kek, new_kek) # re-derives from the same backup
      expect_rotated(v1_rotation)
    end

    it "raises and leaves the live file intact when it opens with neither KEK" do
      unrelated = make_kek # wrapped with a KEK that is neither old nor new
      write_spdk(unrelated)
      expect_chown(spdk_rotation.backup_path(old_kek))
      spdk_rotation.backup(old_kek)
      expect { spdk_rotation.rotate(old_kek, new_kek) }.to raise_error(OpenSSL::Cipher::CipherError)
      expect(File.exist?("#{spdk_file}.new")).to be(false)
      expect(spdk_rotation.plaintexts(spdk_file, unrelated)).to eq(dek) # live untouched, .new never renamed
    end
  end

  describe "#verify" do
    it "fails when the rotated spdk file encodes a different DEK" do
      backup = "#{spdk_file}.old"
      rotated = "#{spdk_file}.new"
      StorageKeyEncryption.new(old_kek).write_encrypted_dek(backup, dek)
      different = {cipher: "AES_XTS", key: SecureRandom.random_bytes(32).unpack1("H*"), key2: dek_key2}
      StorageKeyEncryption.new(new_kek).write_encrypted_dek(rotated, different)
      expect { spdk_rotation.verify(backup, old_kek, rotated, new_kek) }.to raise_error("secrets changed after rotation")
      expect(File.exist?(rotated)).to be(true)
    end

    it "catches a config-v2 non-xts secret that rewrapped to a different value" do
      source = "#{v2_file}.old"
      rotated = "#{v2_file}.new"
      File.write(source, PerfectTOML.generate({"secrets" => {
        "xts-key" => kek_secret(old_kek, "xts-key", xts_plaintext),
        "archive-access-key" => kek_secret(old_kek, "archive-access-key", "AKIA-original"),
      }}))
      File.write(rotated, PerfectTOML.generate({"secrets" => {
        "xts-key" => kek_secret(new_kek, "xts-key", xts_plaintext),
        "archive-access-key" => kek_secret(new_kek, "archive-access-key", "AKIA-corrupted"),
      }}))
      expect { v2_rotation.verify(source, old_kek, rotated, new_kek) }.to raise_error("secrets changed after rotation")
    end
  end

  describe "#rewrap_v2" do
    def expect_secret_rejected(secret, msg)
      File.write(v2_file, PerfectTOML.generate({"secrets" => {"xts-key" => secret}}))
      expect { v2_rotation.rewrap_v2(v2_file, old_kek, new_kek) }.to raise_error(msg)
      expect { v2_rotation.secrets_v2(v2_file, old_kek) }.to raise_error(msg)
    end

    it "fails on a secret that is not an inline base64 kek secret" do
      secret = kek_secret(old_kek, "xts-key", "secret")
      secret["encrypted_by"]["ref"] = "other"
      expect_secret_rejected(secret, "config-v2 secret xts-key is not wrapped by the kek")

      secret = kek_secret(old_kek, "xts-key", "secret")
      secret["encoding"] = "hex"
      expect_secret_rejected(secret, "config-v2 secret xts-key is not base64 encoded")

      secret = kek_secret(old_kek, "xts-key", "secret")
      secret["source"].delete("inline")
      expect_secret_rejected(secret, "config-v2 secret xts-key has no inline value")
    end
  end

  describe "#retire_backup" do
    it "removes the old key's backup, leaving the live file" do
      File.write(v1_file, "current")
      backup = v1_rotation.backup_path(old_kek)
      File.write(backup, "old")
      v1_rotation.retire_backup(old_kek)
      expect(File.exist?(backup)).to be(false)
      expect(File.read(v1_file)).to eq "current"
    end
  end
end
