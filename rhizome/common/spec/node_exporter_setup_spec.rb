# frozen_string_literal: true

require_relative "../lib/node_exporter_setup"

RSpec.describe NodeExporterSetup do
  subject(:setup) { described_class.new }

  let(:file_name) { "node_exporter-1.12.1.linux-#{Arch.render(x64: "amd64", arm64: "arm64")}" }
  let(:tarball) { "#{file_name}.tar.gz" }
  let(:url) { "https://github.com/prometheus/node_exporter/releases/download/v1.12.1/#{tarball}" }
  let(:unit_path) { "/etc/systemd/system/node_exporter.service" }
  let(:base_flags) { "--web.listen-address=127.0.0.1:9100 --collector.textfile.directory=/var/lib/node_exporter" }

  describe "#service" do
    it "listens on localhost only and serves the textfile directory" do
      expect(setup.service).to include "ExecStart=/usr/local/bin/node_exporter #{base_flags}\n"
    end

    it "excludes the per pod collectors on a kubernetes node" do
      setup = described_class.new(kubernetes: true)

      expect(setup.service).to include "ExecStart=/usr/local/bin/node_exporter #{base_flags} #{described_class::KUBERNETES_FLAGS.join(" ")}\n"
    end
  end

  describe "#run" do
    it "installs the binary and configures the service" do
      commands = []
      allow(setup).to receive(:_run_command) { |*command, **| commands << command.join(" ") }
      expect(setup).to receive(:curl_file).with(url, tarball).and_return(described_class::CHECKSUM)
      expect(setup).to receive(:configure) { commands << :configure }

      setup.run

      expect(commands).to eq [
        "tar xfz #{tarball} -C /usr/local/bin --no-same-owner --strip-components=1 #{file_name}/node_exporter",
        "rm #{tarball}",
        :configure,
      ]
    end

    it "fails when the download does not match the pinned checksum" do
      expect(setup).to receive(:curl_file).with(url, tarball).and_return("wrongsha256")

      expect { setup.run }.to raise_error RuntimeError, "Invalid SHA-256 digest"
    end
  end

  describe "#configure" do
    let(:commands) { [] }
    let(:accepted_exit_codes) { {} }

    before do
      allow(setup).to receive(:_run_command) do |*command, **kw|
        commands << command.join(" ")
        accepted_exit_codes[command.join(" ")] = kw[:expect] if kw[:expect]
      end
      expect(FileUtils).to receive(:mkdir_p).with("/var/lib/node_exporter")
    end

    it "writes the unit and restarts the service when the unit is new" do
      expect(File).to receive(:exist?).with(unit_path).and_return(false)
      written = {}
      expect(setup).to receive(:safe_write_to_file) { |path, content| written[path] = content }

      setup.configure

      expect(commands).to eq [
        "groupadd -f --system node_exporter",
        "useradd --no-create-home --system -g node_exporter node_exporter",
        "systemctl daemon-reload",
        "systemctl enable node_exporter",
        "systemctl restart node_exporter",
      ]
      expect(written).to eq(unit_path => setup.service)
      expect(accepted_exit_codes).to eq("useradd --no-create-home --system -g node_exporter node_exporter" => [0, 9])
    end

    it "rewrites and restarts when the installed unit differs" do
      expect(File).to receive(:exist?).with(unit_path).and_return(true)
      expect(File).to receive(:read).with(unit_path).and_return("[Service]\nUser=nobody\n")
      expect(setup).to receive(:safe_write_to_file).with(unit_path, setup.service)

      setup.configure

      expect(commands.last).to eq "systemctl restart node_exporter"
    end

    it "only ensures the service is running when the unit is current" do
      expect(File).to receive(:exist?).with(unit_path).and_return(true)
      expect(File).to receive(:read).with(unit_path).and_return(setup.service)
      expect(setup).not_to receive(:safe_write_to_file)

      setup.configure

      expect(commands).to eq [
        "groupadd -f --system node_exporter",
        "useradd --no-create-home --system -g node_exporter node_exporter",
        "systemctl daemon-reload",
        "systemctl enable node_exporter",
        "systemctl start node_exporter",
      ]
    end
  end
end
