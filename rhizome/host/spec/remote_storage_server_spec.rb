# frozen_string_literal: true

require_relative "../lib/remote_storage_server"

RSpec.describe RemoteStorageServer do
  subject(:server) { described_class.new("vmxyz", "default", 0, "v0.5.0", "v0.5.0") }

  let(:kek_material) { {"key" => "a2V5", "init_vector" => "aXY=", "auth_data" => "vmxyz_0"} }

  describe "#listen_config" do
    it "builds a listen config with the address and PSK" do
      lines = server.listen_config(4600, "cHNrYnl0ZXM=", "ubiblk-rss").split("\n")
      expect(lines).to include("[server]", "address = \"0.0.0.0:4600\"")
      expect(lines).to include("[server.psk]", "identity = \"ubiblk-rss\"", "secret.ref = \"psk\"")
      expect(lines).to include("[secrets.psk]", "source.inline = \"cHNrYnl0ZXM=\"", "encoding = \"base64\"")
    end
  end

  describe "#kek_payload" do
    it "passes the base64 key through for a current-format source" do
      expect(server.kek_payload(kek_material)).to eq("a2V5")
    end

    it "builds a legacy KEK YAML for a v0.2.x source" do
      legacy = described_class.new("vmxyz", "default", 0, "v0.2.2", "v0.5.0")
      yaml = YAML.load(legacy.kek_payload(kek_material))
      expect(yaml["method"]).to eq("aes256-gcm")
      expect(yaml["key"]).to eq("a2V5")
      expect(yaml["auth_data"]).to eq(Base64.strict_encode64("vmxyz_0"))
    end
  end

  describe "#write_listen_config" do
    it "writes the config 0600 to the volume's storage dir" do
      expect(File).to receive(:write).with(%r{vmxyz/0/remote-stripe-listen\.conf}, /\[server\]/)
      expect(File).to receive(:chmod).with(0o600, %r{remote-stripe-listen\.conf})
      server.write_listen_config(4600, "p", "id")
    end
  end

  describe "#run" do
    def stub_run(srv)
      expect(srv).to receive(:write_listen_config)
      expect(srv).to receive(:rm_if_exists)
      expect(File).to receive(:mkfifo)
      expect(FileUtils).to receive(:chown)
      expect(srv).to receive(:fork).and_return(123)
      expect(Process).to receive(:detach).with(123)
    end

    it "refuses server binaries older than v0.5.0" do
      old = described_class.new("vmxyz", "default", 0, "v0.5.0", "v0.4.2")
      expect { old.run(4600, "p", "id", kek_material) }.to raise_error(/v0.5.0 or later/)
    end

    it "execs the v0.5.0 server, no --legacy for a current-format source" do
      stub_run(server)
      expect(server).to receive(:exec) do |env, path, *args|
        expect(path).to eq("/opt/vhost-block-backend/v0.5.0/remote-stripe-server")
        expect(args).to include("-f", "--listen-config")
        expect(args).not_to include("--legacy")
      end
      server.run(4600, "p", "id", kek_material)
    end

    it "adds --legacy for a v0.2.x source, still using the v0.5.0 binary" do
      legacy = described_class.new("vmxyz", "default", 0, "v0.2.2", "v0.5.0")
      stub_run(legacy)
      expect(legacy).to receive(:exec) do |env, path, *args|
        expect(path).to eq("/opt/vhost-block-backend/v0.5.0/remote-stripe-server")
        expect(args).to include("--legacy", "--legacy-kek")
      end
      legacy.run(4600, "p", "id", kek_material)
    end
  end
end
