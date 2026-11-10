# frozen_string_literal: true

require_relative "../lib/minio_configure"

RSpec.describe MinioConfigure do
  subject(:configure) { described_class.new(config) }

  let(:certs) { "/home/minio-user/.minio/certs" }
  let(:config) {
    {
      "minio_config" => "MINIO_VOLUMES=x",
      "hosts" => "::1 localhost",
      "cert" => "cert",
      "cert_key" => "cert_key",
      "ca_bundle" => "ca_bundle",
    }
  }
  let(:commands) { [] }
  let(:written) { {} }

  before do
    allow(configure).to receive(:_run_command) { |*command| commands << command.join(" ") }
    allow(configure).to receive(:safe_write_to_file) { |path, content| written[path] = content }
  end

  describe "#initialize" do
    it "requires minio_config" do
      expect { described_class.new("hosts" => "") }.to raise_error RuntimeError, "need minio_config as argument"
    end

    it "requires hosts" do
      expect { described_class.new("minio_config" => "") }.to raise_error RuntimeError, "need hosts as argument"
    end
  end

  describe "#run" do
    let(:base_written) {
      {
        "/etc/default/minio" => "MINIO_VOLUMES=x",
        "/etc/hosts" => "::1 localhost",
        "/etc/sysctl.d/70-minio.conf" => "net.ipv4.tcp_slow_start_after_idle=0\n",
      }
    }
    let(:base_commands) {
      [
        "sudo chown -R minio-user:minio-user /etc/default/minio",
        "sudo sysctl --quiet --load /etc/sysctl.d/70-minio.conf",
      ]
    }

    it "writes the config, certs, and CA bundle" do
      configure.run

      expect(written).to eq(base_written.merge(
        "#{certs}/public.crt" => "cert",
        "#{certs}/private.key" => "cert_key",
        "#{certs}/CAs/public.crt" => "ca_bundle",
      ))
      expect(commands).to eq base_commands + [
        "sudo mkdir -p #{certs}/CAs",
        "sudo chown -R minio-user:minio-user #{certs}",
      ]
    end

    context "with a peer cert" do
      let(:config) { super().merge("ca_bundle" => "", "peer_cert" => "peer_cert", "peer_cert_key" => "peer_cert_key") }

      it "writes the peer cert" do
        configure.run

        expect(written).to eq(base_written.merge(
          "#{certs}/public.crt" => "cert",
          "#{certs}/private.key" => "cert_key",
          "#{certs}/peer/public.crt" => "peer_cert",
          "#{certs}/peer/private.key" => "peer_cert_key",
        ))
        expect(commands).to eq base_commands + [
          "sudo mkdir -p #{certs}/CAs",
          "sudo mkdir -p #{certs}/peer",
          "sudo chown -R minio-user:minio-user #{certs}",
        ]
      end
    end

    context "without a cert" do
      let(:config) { super().merge("cert" => "") }

      it "skips the certs" do
        configure.run

        expect(written).to eq base_written
        expect(commands).to eq base_commands
      end
    end
  end
end
