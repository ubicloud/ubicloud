# frozen_string_literal: true

require_relative "../lib/parseable_setup"

RSpec.describe ParseableSetup do
  subject(:setup) { described_class.new(["v2.6.5"]) }

  let(:url) { "https://github.com/parseablehq/parseable/releases/download/v2.6.5/Parseable_OSS_x86_64-unknown-linux-gnu" }
  let(:tmp_file) { instance_double(File, path: "#{described_class::BIN_PATH}.tmp") }

  describe "#initialize" do
    it "rejects a missing version" do
      expect { described_class.new([]) }.to raise_error RuntimeError, "expected a single argument, a parseable version like v2.6.5, got 0"
    end

    it "rejects extra arguments" do
      expect { described_class.new(["v2.6.5", "x64"]) }.to raise_error RuntimeError, "expected a single argument, a parseable version like v2.6.5, got 2"
    end

    it "rejects a version there is no checksum for" do
      expect { described_class.new(["v2.6.4"]) }.to raise_error RuntimeError, "no parseable checksum for version \"v2.6.4\""
    end
  end

  describe "#run" do
    it "downloads the binary to a temporary path and makes it executable" do
      expect(setup).to receive(:safe_write_to_file).with(described_class::BIN_PATH).and_yield(tmp_file)
      expect(setup).to receive(:curl_file).with(url, tmp_file.path).and_return(described_class::CHECKSUMS.fetch("v2.6.5"))
      expect(FileUtils).to receive(:chmod).with("a+x", described_class::BIN_PATH)

      setup.run
    end

    it "fails without making anything executable when the digest does not match" do
      expect(setup).to receive(:safe_write_to_file).with(described_class::BIN_PATH).and_yield(tmp_file)
      expect(setup).to receive(:curl_file).with(url, tmp_file.path).and_return("wrongsha256")
      expect(FileUtils).not_to receive(:chmod)

      expect { setup.run }.to raise_error RuntimeError, "Invalid SHA-256 digest"
    end
  end
end
