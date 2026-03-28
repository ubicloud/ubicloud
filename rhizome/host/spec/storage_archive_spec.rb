# frozen_string_literal: true

require_relative "../lib/storage_archive"

RSpec.describe StorageArchive do
  let(:disk_config_path) { "/var/storage/test/2/vhost-backend.conf" }
  let(:disk_kek_path) { "/var/storage/test/2/kek.pipe" }
  let(:disk_kek) { {"algorithm" => "aes-256-gcm", "key" => "Zm9v"} }
  let(:target_conf) {
    {
      "bucket" => "test-bucket",
      "prefix" => "test-prefix",
      "region" => "us-east-1",
      "endpoint" => "https://s3.example.com",
      "access_key_id" => "abc",
      "secret_access_key" => "def",
      "archive_kek" => {"algorithm" => "aes-256-gcm", "key" => "Zm9v"},
    }
  }

  describe "#initialize" do
    it "validates target configuration keys" do
      invalid_target_conf = target_conf.dup
      invalid_target_conf.delete("bucket")

      expect {
        described_class.new(disk_config_path, disk_kek_path, disk_kek, invalid_target_conf, "v0.4.0")
      }.to raise_error(ArgumentError, "Missing required keys in target_conf: bucket")
    end

    it "fails when vhost block backend does not support archive" do
      expect {
        described_class.new(disk_config_path, disk_kek_path, disk_kek, target_conf, "v0.3.0")
      }.to raise_error(RuntimeError, "vhost block backend version v0.3.0 does not support archive")
    end

    it "fails when disk KEK algorithm is unsupported" do
      invalid_disk_kek = {"algorithm" => "rsa", "key" => "Zm9v"}

      expect {
        described_class.new(disk_config_path, disk_kek_path, invalid_disk_kek, target_conf, "v0.4.0")
      }.to raise_error(RuntimeError, "unsupported key encryption algorithm rsa for disk_kek")
    end

    it "does not require disk KEK" do
      expect {
        described_class.new(disk_config_path, nil, nil, target_conf, "v0.4.0")
      }.not_to raise_error
    end

    it "fails when disk KEK is provided without path" do
      expect {
        described_class.new(disk_config_path, nil, disk_kek, target_conf, "v0.4.0")
      }.to raise_error(RuntimeError, "disk KEK provided without path")
    end

    it "fails when disk KEK path is provided without KEK" do
      expect {
        described_class.new(disk_config_path, disk_kek_path, nil, target_conf, "v0.4.0")
      }.to raise_error(RuntimeError, "disk KEK path provided without KEK")
    end

    it "fails when target archive KEK algorithm is unsupported" do
      invalid_target_conf = target_conf.merge("archive_kek" => {"algorithm" => "rsa", "key" => "Zm9v"})

      expect {
        described_class.new(disk_config_path, disk_kek_path, disk_kek, invalid_target_conf, "v0.4.0")
      }.to raise_error(RuntimeError, "unsupported key encryption algorithm rsa for target_conf archive_kek")
    end
  end

  describe "#build_target_config" do
    it "includes session token configuration when provided" do
      archive = described_class.new(disk_config_path, disk_kek_path, disk_kek, target_conf.merge("session_token" => "ghi"), "v0.4.0")
      config = archive.build_target_config.lines.map(&:strip)

      expect(config).to include("session_token.ref = \"s3-session-token\"")
      expect(config).to include("[secrets.s3-session-token]")
      expect(config).to include("allow_inline_plaintext_secrets = true")
    end

    it "builds the target config" do
      archive = described_class.new(disk_config_path, disk_kek_path, disk_kek, target_conf, "v0.4.0")
      config = archive.build_target_config
      expected_config = <<~CONFIG
[target]
storage = "s3"
bucket = "test-bucket"
prefix = "test-prefix"
region = "us-east-1"
endpoint = "https://s3.example.com"
access_key_id.ref = "s3-key-id"
secret_access_key.ref = "s3-secret-key"
archive_kek.ref = "archive-kek"

[secrets.s3-key-id]
source.inline = "abc"

[secrets.s3-secret-key]
source.inline = "def"

[secrets.archive-kek]
source.inline = "Zm9v"
encoding = "base64"

[danger_zone]
enabled = true
allow_inline_plaintext_secrets = true
      CONFIG
      expect(config).to eq(expected_config)
    end
  end

  describe "#archive" do
    it "uses KEK pipe flow when disk KEK path is set" do
      archive = described_class.new(disk_config_path, disk_kek_path, disk_kek, target_conf, "v0.4.0")
      built_config = "[target]\n"
      allow(archive).to receive(:build_target_config).and_return(built_config)

      expect(archive).to receive(:run_with_kek_pipe).with(
        [
          "/opt/vhost-block-backend/v0.4.0/archive",
          "--config", disk_config_path,
          "--target-config", "/dev/stdin",
          "--compression", "zstd",
          "--zstd-level", "3",
        ],
        kek_pipe: disk_kek_path,
        kek_content: "Zm9v",
        env: {"RUST_LOG" => "info"},
        stdin: built_config,
      )

      archive.archive
    end

    it "runs archive command directly when disk KEK path is not set" do
      archive = described_class.new(disk_config_path, nil, nil, target_conf, "v0.4.0")
      built_config = "[target]\n"
      allow(archive).to receive(:build_target_config).and_return(built_config)

      expect(archive).to receive(:r).with(
        {"RUST_LOG" => "info"},
        "/opt/vhost-block-backend/v0.4.0/archive",
        "--config", disk_config_path,
        "--target-config", "/dev/stdin",
        "--compression", "zstd",
        "--zstd-level", "3",
        stdin: built_config,
      )

      archive.archive
    end
  end

  describe ".archive_url" do
    it "downloads image, creates disk with rounded-up size, writes config, and archives" do
      tmpdir = "/tmp/test-archive-url"
      boot_image = instance_double(BootImage, image_path: "#{tmpdir}/image.raw")
      archive_instance = instance_double(described_class)
      vp = instance_double(VhostBlockBackend, init_metadata_path: "/opt/vhost-block-backend/v0.4.0/init-metadata")

      allow(Dir).to receive(:mktmpdir).and_yield(tmpdir)
      allow(BootImage).to receive(:new).with("image", nil, image_root: tmpdir).and_return(boot_image)
      allow(File).to receive(:size).with(boot_image.image_path).and_return(1024 * 1024 * 5 + 1)

      expect(boot_image).to receive(:download).with(url: "https://example.com/image.raw", sha256sum: "abc123")
      expect(described_class).to receive(:r).with("truncate", "-s", "6M", "#{tmpdir}/disk.raw")
      expect(described_class).to receive(:safe_write_to_file).with("#{tmpdir}/vhost-backend.conf", <<~CONFIG,
[device]
data_path = "/tmp/test-archive-url/disk.raw"
metadata_path = "/tmp/test-archive-url/metadata"

[stripe_source]
type = "raw"
image_path = "/tmp/test-archive-url/image.raw"

[danger_zone]
enabled = true
allow_unencrypted_disk = true
      CONFIG
      )
      expect(VhostBlockBackend).to receive(:new).with("v0.4.0").and_return(vp)
      expect(described_class).to receive(:r).with({"RUST_LOG" => "info"}, vp.init_metadata_path, "--config", "#{tmpdir}/vhost-backend.conf")
      expect(described_class).to receive(:new).with("#{tmpdir}/vhost-backend.conf", nil, nil, target_conf, "v0.4.0").and_return(archive_instance)
      expect(archive_instance).to receive(:archive)

      described_class.archive_url("https://example.com/image.raw", "abc123", target_conf, "v0.4.0")
    end
  end
end
