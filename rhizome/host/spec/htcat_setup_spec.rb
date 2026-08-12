# frozen_string_literal: true

require_relative "../lib/htcat_setup"

RSpec.describe HtcatSetup do
  subject(:setup) { described_class.new }

  let(:tarball) { "htcat_2.0.0-ubi1_linux_#{Arch.render(x64: "amd64", arm64: "arm64")}.tar.gz" }
  let(:url) { "https://github.com/ubicloud/htcat/releases/download/v2.0.0-ubi1/#{tarball}" }

  describe "#run" do
    it "installs the binary and removes the tarball" do
      commands = []
      allow(setup).to receive(:_run_command) { |*command| commands << command.join(" ") }
      expect(setup).to receive(:curl_file).with(url, tarball).and_return(described_class::CHECKSUM)

      setup.run

      expect(commands).to eq [
        "tar xfz #{tarball} -C /usr/local/bin --no-same-owner htcat",
        "rm #{tarball}",
      ]
    end

    it "fails when the download does not match the pinned checksum" do
      expect(setup).to receive(:curl_file).with(url, tarball).and_return("wrongsha256")

      expect { setup.run }.to raise_error RuntimeError, "Invalid SHA-256 digest"
    end
  end
end
