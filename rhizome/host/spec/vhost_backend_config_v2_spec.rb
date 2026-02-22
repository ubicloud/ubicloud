# frozen_string_literal: true

require_relative "../lib/vhost_backend_config_v2"
require "openssl"
require "base64"

RSpec.describe VhostBackendConfigV2 do
  let(:base_params) {
    {
      disk_file: "/var/storage/test/2/disk.raw",
      vhost_sock: "/var/storage/test/2/vhost.sock",
      rpc_socket_path: "/var/storage/test/2/rpc.sock",
      device_id: "xyz01",
      num_queues: 4,
      queue_size: 128,
      copy_on_read: false,
      write_through: false,
      skip_sync: false,
      image_path: nil,
      metadata_path: nil,
      cpus: nil,
      encrypted: false,
      encryption_key: nil,
      kek: nil,
      kek_pipe: nil,
      stripe_source_config_path: "/var/storage/test/2/stripe_source.toml",
      secrets_config_path: "/var/storage/test/2/secrets.toml"
    }
  }

  describe "#main_toml" do
    it "includes track_written = true in the device section" do
      config = described_class.new(base_params)
      toml = config.main_toml
      expect(toml).to include("track_written = true")
    end

    it "includes all required device fields" do
      config = described_class.new(base_params)
      toml = config.main_toml
      expect(toml).to include('[device]')
      expect(toml).to include('data_path = "/var/storage/test/2/disk.raw"')
      expect(toml).to include('vhost_socket = "/var/storage/test/2/vhost.sock"')
      expect(toml).to include('rpc_socket = "/var/storage/test/2/rpc.sock"')
      expect(toml).to include('device_id = "xyz01"')
      expect(toml).to include("track_written = true")
    end

    it "includes metadata_path when image_path is set" do
      params = base_params.merge(
        image_path: "/var/storage/images/ubuntu.raw",
        metadata_path: "/var/storage/test/2/metadata"
      )
      config = described_class.new(params)
      toml = config.main_toml
      expect(toml).to include('metadata_path = "/var/storage/test/2/metadata"')
    end

    it "includes tuning fields" do
      config = described_class.new(base_params)
      toml = config.main_toml
      expect(toml).to include("[tuning]")
      expect(toml).to include("num_queues = 4")
      expect(toml).to include("queue_size = 128")
    end

    it "includes cpus in tuning when provided" do
      params = base_params.merge(cpus: [0, 1, 2, 3])
      config = described_class.new(params)
      toml = config.main_toml
      expect(toml).to include("cpus = [0, 1, 2, 3]")
    end
  end

  describe "#stripe_source_toml" do
    it "returns nil when no image_path" do
      config = described_class.new(base_params)
      expect(config.stripe_source_toml).to be_nil
    end

    it "returns stripe source config when image_path is set" do
      params = base_params.merge(
        image_path: "/var/storage/images/ubuntu.raw",
        metadata_path: "/var/storage/test/2/metadata"
      )
      config = described_class.new(params)
      toml = config.stripe_source_toml
      expect(toml).to include("[stripe_source]")
      expect(toml).to include('type = "raw"')
      expect(toml).to include('image_path = "/var/storage/images/ubuntu.raw"')
      expect(toml).to include("copy_on_read = false")
    end
  end
end
