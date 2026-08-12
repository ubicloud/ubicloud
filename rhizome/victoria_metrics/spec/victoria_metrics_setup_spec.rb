# frozen_string_literal: true

require_relative "../lib/victoria_metrics_setup"

RSpec.describe VictoriaMetricsSetup do
  subject(:setup) { described_class.new(["v1.149.0"]) }

  let(:base_url) { "https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.149.0" }

  describe "#initialize" do
    it "rejects a missing version" do
      expect { described_class.new([]) }.to raise_error RuntimeError, "expected a single argument, a VictoriaMetrics version like v1.149.0, got 0"
    end

    it "rejects extra arguments" do
      expect { described_class.new(["v1.149.0", "amd64"]) }.to raise_error RuntimeError, "expected a single argument, a VictoriaMetrics version like v1.149.0, got 2"
    end

    it "rejects a version there is no checksum for" do
      expect { described_class.new(["v1.148.0"]) }.to raise_error RuntimeError, "no VictoriaMetrics checksums for version \"v1.148.0\""
    end
  end

  describe "#run" do
    it "installs both tarballs and removes them" do
      commands = []
      allow(setup).to receive(:_run_command) { |*command| commands << command.join(" ") }
      checksums = described_class::CHECKSUMS.fetch("v1.149.0")
      expect(setup).to receive(:curl_file).with("#{base_url}/victoria-metrics-linux-amd64-v1.149.0.tar.gz", "victoria-metrics-linux-amd64-v1.149.0.tar.gz").and_return(checksums.fetch("victoria-metrics"))
      expect(setup).to receive(:curl_file).with("#{base_url}/vmutils-linux-amd64-v1.149.0.tar.gz", "vmutils-linux-amd64-v1.149.0.tar.gz").and_return(checksums.fetch("vmutils"))

      setup.run

      expect(commands).to eq [
        "tar xfz victoria-metrics-linux-amd64-v1.149.0.tar.gz -C /usr/local/bin --no-same-owner",
        "rm victoria-metrics-linux-amd64-v1.149.0.tar.gz",
        "tar xfz vmutils-linux-amd64-v1.149.0.tar.gz -C /usr/local/bin --no-same-owner",
        "rm vmutils-linux-amd64-v1.149.0.tar.gz",
      ]
    end

    it "fails when the download does not match the pinned checksum" do
      expect(setup).to receive(:curl_file).with("#{base_url}/victoria-metrics-linux-amd64-v1.149.0.tar.gz", "victoria-metrics-linux-amd64-v1.149.0.tar.gz").and_return("wrongsha256")

      expect { setup.run }.to raise_error RuntimeError, "Invalid SHA-256 digest"
    end
  end
end
