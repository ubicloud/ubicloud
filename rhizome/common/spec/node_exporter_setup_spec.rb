# frozen_string_literal: true

require_relative "../lib/node_exporter_setup"

RSpec.describe NodeExporterSetup do
  subject(:setup) { described_class.new }

  let(:file_name) { "node_exporter-1.12.1.linux-#{Arch.render(x64: "amd64", arm64: "arm64")}" }
  let(:tarball) { "#{file_name}.tar.gz" }
  let(:url) { "https://github.com/prometheus/node_exporter/releases/download/v1.12.1/#{tarball}" }

  describe "#service" do
    it "listens on localhost only" do
      expect(setup.service).to include "ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100\n"
    end

    it "excludes the per pod collectors on a kubernetes node" do
      setup = described_class.new(kubernetes: true)

      expect(setup.service).to include "ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100 #{described_class::KUBERNETES_FLAGS.join(" ")}\n"
    end
  end

  describe "#run" do
    it "installs the binary and starts the service" do
      commands = []
      accepted_exit_codes = {}
      allow(setup).to receive(:_run_command) do |*command, **kw|
        commands << command.join(" ")
        accepted_exit_codes[command.join(" ")] = kw[:expect] if kw[:expect]
      end
      written = {}
      allow(setup).to receive(:safe_write_to_file) { |path, content| written[path] = content }
      expect(setup).to receive(:curl_file).with(url, tarball).and_return(described_class::CHECKSUM)

      setup.run

      expect(commands).to eq [
        "tar xfz #{tarball} -C /usr/local/bin --no-same-owner --strip-components=1 #{file_name}/node_exporter",
        "rm #{tarball}",
        "groupadd -f --system node_exporter",
        "useradd --no-create-home --system -g node_exporter node_exporter",
        "systemctl daemon-reload",
        "systemctl enable node_exporter",
        "systemctl start node_exporter",
      ]
      expect(written).to eq("/etc/systemd/system/node_exporter.service" => setup.service)
      expect(accepted_exit_codes).to eq("useradd --no-create-home --system -g node_exporter node_exporter" => [0, 9])
    end

    it "fails when the download does not match the pinned checksum" do
      expect(setup).to receive(:curl_file).with(url, tarball).and_return("wrongsha256")

      expect { setup.run }.to raise_error RuntimeError, "Invalid SHA-256 digest"
    end
  end
end
