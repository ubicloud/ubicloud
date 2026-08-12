# frozen_string_literal: true

require_relative "../lib/minio_setup"

RSpec.describe MinioSetup do
  subject(:setup) { described_class.new(["minio_20250723155402.0.0_amd64"]) }

  let(:package) { "minio_20250723155402.0.0_amd64.deb" }
  let(:url) { "https://dl.min.io/server/minio/release/linux-amd64/archive/#{package}" }

  describe "#initialize" do
    it "rejects a missing version" do
      expect { described_class.new([]) }.to raise_error RuntimeError, "expected a single argument, a minio version like minio_20250723155402.0.0_amd64, got 0"
    end

    it "rejects extra arguments" do
      expect { described_class.new(["minio_20250723155402.0.0_amd64", "amd64"]) }.to raise_error RuntimeError, "expected a single argument, a minio version like minio_20250723155402.0.0_amd64, got 2"
    end

    it "rejects a version there is no checksum for" do
      expect { described_class.new(["minio_20240101000000.0.0_amd64"]) }.to raise_error RuntimeError, "no minio checksum for version \"minio_20240101000000.0.0_amd64\""
    end
  end

  describe "#run" do
    it "installs the package and enables the service" do
      commands = []
      allow(setup).to receive(:_run_command) { |*command| commands << command.join(" ") }
      expect(setup).to receive(:curl_file).with(url, package).and_return(described_class::CHECKSUMS.fetch("minio_20250723155402.0.0_amd64"))

      setup.run

      expect(commands).to eq [
        "dpkg -i #{package}",
        "rm #{package}",
        "systemctl enable minio.service",
      ]
    end

    it "fails without installing anything when the digest does not match" do
      commands = []
      allow(setup).to receive(:_run_command) { |*command| commands << command.join(" ") }
      expect(setup).to receive(:curl_file).with(url, package).and_return("wrongsha256")

      expect { setup.run }.to raise_error RuntimeError, "Invalid SHA-256 digest"
      expect(commands).to eq []
    end
  end
end
