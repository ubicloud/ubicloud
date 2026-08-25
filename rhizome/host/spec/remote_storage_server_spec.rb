# frozen_string_literal: true

require_relative "../lib/remote_storage_server"

RSpec.describe RemoteStorageServer do
  subject(:server) { described_class.new("vmxyz", "default", 0, "v0.5.0", "v0.5.0") }

  let(:kek_material) { {"key" => "a2V5", "init_vector" => "aXY=", "auth_data" => "vmxyz_0"} }

  describe "#listen_config" do
    it "builds a listen config with the address and PSK" do
      config = PerfectTOML.parse(server.listen_config(4600, "cHNrYnl0ZXM=", "ubiblk-rss"))
      expect(config["server"]).to eq({"address" => "0.0.0.0:4600", "psk" => {"identity" => "ubiblk-rss", "secret" => {"ref" => "psk"}}})
      expect(config["secrets"]["psk"]).to eq({"source" => {"inline" => "cHNrYnl0ZXM="}, "encoding" => "base64"})
    end
  end

  describe "#kek_payload" do
    it "passes the base64 key through for a current-format source" do
      expect(server.kek_payload(kek_material)).to eq("a2V5")
    end

    it "builds a legacy KEK YAML for a v0.2.x source" do
      legacy = described_class.new("vmxyz", "default", 0, "v0.2.2", "v0.5.0")
      yaml = YAML.safe_load(legacy.kek_payload(kek_material))
      expect(yaml["method"]).to eq("aes256-gcm")
      expect(yaml["key"]).to eq("a2V5")
      expect(yaml["auth_data"]).to eq(Base64.strict_encode64("vmxyz_0"))
    end
  end

  describe "#run" do
    it "refuses server binaries older than v0.5.0" do
      old = described_class.new("vmxyz", "default", 0, "v0.5.0", "v0.4.2")
      expect { old.run(4600, "p", "id", kek_material) }.to raise_error(/v0.5.0 or later/)
    end

    it "execs the v0.5.0 server, no --legacy for a current-format source" do
      expect(server).to receive(:run_with_kek_pipe).with(
        [
          "/opt/vhost-block-backend/v0.5.0/remote-stripe-server",
          "-f",
          "/var/storage/devices/default/vmxyz/0/vhost-backend.conf",
          "--listen-config",
          "/dev/stdin",
        ],
        {
          env: {"RUST_LOG" => "info"},
          kek_content: "a2V5",
          kek_pipe: "/var/storage/devices/default/vmxyz/0/kek.pipe",
          stdin: satisfy { |s|
            PerfectTOML.parse(s) == {
              "server" => {"address" => "0.0.0.0:4600", "psk" => {"identity" => "id", "secret" => {"ref" => "psk"}}},
              "secrets" => {"psk" => {"source" => {"inline" => "p"}, "encoding" => "base64"}},
              "danger_zone" => {"enabled" => true, "allow_inline_plaintext_secrets" => true},
            }
          },
        },
      )
      server.run(4600, "p", "id", kek_material)
    end

    it "adds --legacy for a v0.2.x source, still using the v0.5.0 binary" do
      legacy = described_class.new("vmxyz", "default", 0, "v0.2.2", "v0.5.0")
      expect(legacy).to receive(:run_with_kek_pipe).with(
        [
          "/opt/vhost-block-backend/v0.5.0/remote-stripe-server",
          "-f",
          "/var/storage/devices/default/vmxyz/0/vhost-backend.conf",
          "--legacy",
          "--legacy-kek",
          "/var/storage/devices/default/vmxyz/0/kek.pipe",
          "--listen-config",
          "/dev/stdin",
        ],
        {
          env: {"RUST_LOG" => "info"},
          kek_content: <<~END,
            ---
            method: aes256-gcm
            key: a2V5
            init_vector: aXY=
            auth_data: dm14eXpfMA==
          END
          kek_pipe: "/var/storage/devices/default/vmxyz/0/kek.pipe",
          stdin: satisfy { |s|
            PerfectTOML.parse(s) == {
              "server" => {"address" => "0.0.0.0:4600", "psk" => {"identity" => "id", "secret" => {"ref" => "psk"}}},
              "secrets" => {"psk" => {"source" => {"inline" => "p"}, "encoding" => "base64"}},
              "danger_zone" => {"enabled" => true, "allow_inline_plaintext_secrets" => true},
            }
          },
        },
      )
      legacy.run(4600, "p", "id", kek_material)
    end
  end
end
