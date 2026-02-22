# frozen_string_literal: true

require_relative "../lib/vhost_backend_config_v2"
require "openssl"
require "base64"

RSpec.describe VhostBackendConfigV2 do
  let(:base_params) {
    {
      disk_file: "/var/storage/test/0/disk.raw",
      vhost_sock: "/var/storage/test/0/vhost.sock",
      rpc_socket_path: "/var/storage/test/0/rpc.sock",
      device_id: "test_0",
      num_queues: 4,
      queue_size: 64,
      stripe_source_config_path: "/var/storage/test/0/vhost-backend-stripe-source.conf",
      secrets_config_path: "/var/storage/test/0/vhost-backend-secrets.conf"
    }
  }

  let(:kek_secrets) {
    algorithm = "aes-256-gcm"
    cipher = OpenSSL::Cipher.new(algorithm)
    {
      "algorithm" => algorithm,
      "key" => Base64.encode64(cipher.random_key),
      "init_vector" => Base64.encode64(cipher.random_iv),
      "auth_data" => "test-auth-data"
    }
  }

  describe "raw stripe source (boot image)" do
    it "generates stripe source toml for raw image" do
      config = described_class.new(base_params.merge(image_path: "/var/storage/images/ubuntu.raw"))
      toml = config.stripe_source_toml
      expect(toml).to include('type = "raw"')
      expect(toml).to include('image_path = "/var/storage/images/ubuntu.raw"')
      expect(toml).to include("copy_on_read = false")
    end

    it "returns nil stripe source when no image" do
      config = described_class.new(base_params)
      expect(config.stripe_source_toml).to be_nil
    end

    it "returns nil secrets when not encrypted" do
      config = described_class.new(base_params.merge(image_path: "/var/storage/images/ubuntu.raw"))
      expect(config.secrets_toml).to be_nil
    end

    it "includes stripe source in includes" do
      config = described_class.new(base_params.merge(image_path: "/var/storage/images/ubuntu.raw"))
      toml = config.main_toml
      expect(toml).to include("vhost-backend-stripe-source.conf")
      expect(toml).not_to include("vhost-backend-secrets.conf")
    end
  end

  describe "archive stripe source (machine image)" do
    let(:archive_params) {
      {
        "type" => "archive",
        "archive_bucket" => "ubi-images",
        "archive_prefix" => "images/abc123",
        "archive_endpoint" => "https://r2.example.com",
        "stripe_sector_count" => 2048,
        "compression" => "zstd",
        "encrypted" => false
      }
    }

    let(:archive_config_params) {
      base_params.merge(
        archive_params: archive_params,
        s3_key_id_pipe: "/var/storage/test/0/s3-key-id.pipe",
        s3_secret_key_pipe: "/var/storage/test/0/s3-secret-key.pipe",
        s3_session_token_pipe: "/var/storage/test/0/s3-session-token.pipe",
        archive_kek_pipe: "/var/storage/test/0/archive-kek.pipe"
      )
    }

    it "generates archive stripe source toml" do
      config = described_class.new(archive_config_params)
      toml = config.stripe_source_toml
      expect(toml).to include('type = "archive"')
      expect(toml).to include('storage = "s3"')
      expect(toml).to include('bucket = "ubi-images"')
      expect(toml).to include('prefix = "images/abc123"')
      expect(toml).to include('endpoint = "https://r2.example.com"')
      expect(toml).to include("connections = 16")
      expect(toml).to include("autofetch = true")
      expect(toml).to include('access_key_id.ref = "s3-key-id"')
      expect(toml).to include('secret_access_key.ref = "s3-secret-key"')
      expect(toml).to include('session_token.ref = "s3-session-token"')
    end

    it "does not include archive_kek ref for unencrypted archives" do
      config = described_class.new(archive_config_params)
      toml = config.stripe_source_toml
      expect(toml).not_to include("archive_kek")
    end

    it "includes archive_kek ref for encrypted archives" do
      encrypted_archive_params = archive_params.merge("encrypted" => true)
      config = described_class.new(archive_config_params.merge(archive_params: encrypted_archive_params))
      toml = config.stripe_source_toml
      expect(toml).to include('archive_kek.ref = "archive-kek"')
    end

    it "generates S3 secrets toml with pipe sources including session token" do
      config = described_class.new(archive_config_params)
      toml = config.secrets_toml
      expect(toml).to include("[secrets.s3-key-id]")
      expect(toml).to include('source.file = "/var/storage/test/0/s3-key-id.pipe"')
      expect(toml).to include("[secrets.s3-secret-key]")
      expect(toml).to include('source.file = "/var/storage/test/0/s3-secret-key.pipe"')
      expect(toml).to include("[secrets.s3-session-token]")
      expect(toml).to include('source.file = "/var/storage/test/0/s3-session-token.pipe"')
      expect(toml).not_to include("source.inline")
    end

    it "generates archive KEK secret for encrypted archives" do
      encrypted_archive_params = archive_params.merge("encrypted" => true)
      config = described_class.new(archive_config_params.merge(archive_params: encrypted_archive_params))
      toml = config.secrets_toml
      expect(toml).to include("[secrets.archive-kek]")
      expect(toml).to include('source.file = "/var/storage/test/0/archive-kek.pipe"')
      expect(toml).to include('encoding = "base64"')
    end

    it "does not include archive KEK secret for unencrypted archives" do
      config = described_class.new(archive_config_params)
      toml = config.secrets_toml
      expect(toml).not_to include("[secrets.archive-kek]")
    end

    it "includes both stripe source and secrets in includes" do
      config = described_class.new(archive_config_params)
      toml = config.main_toml
      expect(toml).to include("vhost-backend-stripe-source.conf")
      expect(toml).to include("vhost-backend-secrets.conf")
    end

    it "reports archive? as true" do
      config = described_class.new(archive_config_params)
      expect(config.archive?).to be true
    end
  end

  describe "archive with disk encryption" do
    let(:archive_params) {
      {
        "type" => "archive",
        "archive_bucket" => "ubi-images",
        "archive_prefix" => "images/abc123",
        "archive_endpoint" => "https://r2.example.com",
        "stripe_sector_count" => 2048,
        "compression" => "zstd",
        "encrypted" => true
      }
    }

    it "generates both disk encryption and archive secrets" do
      encryption_key = {
        key: "a" * 32,
        key2: "b" * 32
      }

      config = described_class.new(base_params.merge(
        encrypted: true,
        encryption_key: encryption_key,
        kek: kek_secrets,
        kek_pipe: "/var/storage/test/0/kek.pipe",
        archive_params: archive_params,
        s3_key_id_pipe: "/var/storage/test/0/s3-key-id.pipe",
        s3_secret_key_pipe: "/var/storage/test/0/s3-secret-key.pipe",
        s3_session_token_pipe: "/var/storage/test/0/s3-session-token.pipe",
        archive_kek_pipe: "/var/storage/test/0/archive-kek.pipe"
      ))

      toml = config.secrets_toml
      # Disk encryption secrets
      expect(toml).to include("[secrets.xts-key]")
      expect(toml).to include("[secrets.kek]")
      # Archive secrets
      expect(toml).to include("[secrets.s3-key-id]")
      expect(toml).to include("[secrets.s3-secret-key]")
      expect(toml).to include("[secrets.archive-kek]")
    end

    it "includes encryption section in main toml" do
      encryption_key = {
        key: "a" * 32,
        key2: "b" * 32
      }

      config = described_class.new(base_params.merge(
        encrypted: true,
        encryption_key: encryption_key,
        kek: kek_secrets,
        kek_pipe: "/var/storage/test/0/kek.pipe",
        archive_params: archive_params,
        s3_key_id_pipe: "/var/storage/test/0/s3-key-id.pipe",
        s3_secret_key_pipe: "/var/storage/test/0/s3-secret-key.pipe",
        s3_session_token_pipe: "/var/storage/test/0/s3-session-token.pipe",
        archive_kek_pipe: "/var/storage/test/0/archive-kek.pipe"
      ))

      toml = config.main_toml
      expect(toml).to include("[encryption]")
      expect(toml).to include('xts_key.ref = "xts-key"')
    end
  end

  describe "main_toml structure" do
    it "generates device and tuning sections" do
      config = described_class.new(base_params)
      toml = config.main_toml
      expect(toml).to include("[device]")
      expect(toml).to include('data_path = "/var/storage/test/0/disk.raw"')
      expect(toml).to include("[tuning]")
      expect(toml).to include("num_queues = 4")
      expect(toml).to include("queue_size = 64")
    end

    it "includes cpus when specified" do
      config = described_class.new(base_params.merge(cpus: [0, 1, 2]))
      toml = config.main_toml
      expect(toml).to include("cpus = [0, 1, 2]")
    end

    it "includes metadata_path when set" do
      config = described_class.new(base_params.merge(
        image_path: "/img.raw",
        metadata_path: "/var/storage/test/0/metadata"
      ))
      toml = config.main_toml
      expect(toml).to include('metadata_path = "/var/storage/test/0/metadata"')
    end
  end
end
