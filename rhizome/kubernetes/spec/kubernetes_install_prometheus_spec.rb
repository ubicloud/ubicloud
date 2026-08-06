# frozen_string_literal: true

require_relative "../lib/kubernetes_install_prometheus"

RSpec.describe KubernetesInstallPrometheus do
  subject(:installer) { described_class.new }

  let(:tarball) { "prometheus-3.13.2.linux-amd64.tar.gz" }
  let(:url) { "https://github.com/prometheus/prometheus/releases/download/v3.13.2/#{tarball}" }

  describe "#run" do
    it "installs the binary and the unit without enabling it" do
      commands = []
      accepted_exit_codes = {}
      allow(installer).to receive(:_run_command) do |*command, **kw|
        commands << command.join(" ")
        accepted_exit_codes[command.join(" ")] = kw[:expect] if kw[:expect]
      end
      written = {}
      allow(installer).to receive(:safe_write_to_file) { |path, content| written[path] = content }
      expect(installer).to receive(:curl_file).with(url, tarball).and_return(described_class::CHECKSUM)

      installer.run

      expect(commands).to eq [
        "tar xfz #{tarball} -C /usr/local/bin --no-same-owner --strip-components=1 prometheus-3.13.2.linux-amd64/prometheus",
        "rm #{tarball}",
        "groupadd -f --system prometheus",
        "useradd --no-create-home --system -g prometheus prometheus",
        "mkdir -p /etc/prometheus /var/lib/prometheus",
        "chown prometheus:prometheus /var/lib/prometheus",
        "systemctl daemon-reload",
      ]
      expect(written).to eq("/etc/systemd/system/prometheus.service" => described_class::SERVICE)
      expect(accepted_exit_codes).to eq("useradd --no-create-home --system -g prometheus prometheus" => [0, 9])
    end

    it "fails when the download does not match the pinned checksum" do
      expect(installer).to receive(:curl_file).with(url, tarball).and_return("deadbeef")

      expect { installer.run }.to raise_error RuntimeError, "Invalid SHA-256 digest"
    end
  end
end
