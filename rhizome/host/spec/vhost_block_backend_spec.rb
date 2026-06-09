# frozen_string_literal: true

require_relative "../lib/vhost_block_backend"

RSpec.describe VhostBlockBackend do
  describe "#config_v2?" do
    it "returns true for v0.4.0 and later" do
      expect(described_class.new("v0.4.0").config_v2?).to be true
      expect(described_class.new("v0.4.2").config_v2?).to be true
    end

    it "returns false for versions before v0.4.0" do
      expect(described_class.new("v0.3.1").config_v2?).to be false
      expect(described_class.new("v0.2.2").config_v2?).to be false
    end
  end

  describe "#supports_archive?" do
    it "returns true for v0.4.0 and later" do
      expect(described_class.new("v0.4.2").supports_archive?).to be true
    end

    it "returns false for versions before v0.4.0" do
      expect(described_class.new("v0.3.1").supports_archive?).to be false
    end
  end

  describe "#sha256" do
    it "returns the sha256 for a known version and arch" do
      allow(Arch).to receive(:sym).and_return(:x64)
      backend = described_class.new("v0.4.2")
      expect(backend.sha256).to eq("e7e430f2e722a2d5d7c18a4f609360e003798d481e26da6db380e698ccb079eb")
    end

    it "returns the sha256 for arm64" do
      allow(Arch).to receive(:sym).and_return(:arm64)
      backend = described_class.new("v0.4.2")
      expect(backend.sha256).to eq("ada92fe076e49f731f5d343d445b1e80d7685b811c33cde7fe88918e93649093")
    end

    it "fails for an unsupported version" do
      allow(Arch).to receive(:sym).and_return(:x64)
      backend = described_class.new("v9.9.9")
      expect { backend.sha256 }.to raise_error(/Unsupported version/)
    end
  end

  describe "#url" do
    it "returns a tar.gz URL with ubiblk prefix for v0.4.0 and later" do
      allow(Arch).to receive(:sym).and_return(:x64)
      backend = described_class.new("v0.4.2")
      expect(backend.url).to eq("https://github.com/ubicloud/ubiblk/releases/download/v0.4.2/ubiblk-x64.tar.gz")
    end

    it "returns a vhost-backend URL for versions before v0.4.0" do
      allow(Arch).to receive(:sym).and_return(:x64)
      backend = described_class.new("v0.3.1")
      expect(backend.url).to eq("https://github.com/ubicloud/ubiblk/releases/download/v0.3.1/vhost-backend-x64.tar.gz")
    end

    it "uses the correct arch in the URL" do
      allow(Arch).to receive(:sym).and_return(:arm64)
      backend = described_class.new("v0.4.2")
      expect(backend.url).to include("arm64")
    end
  end

  describe "#dir" do
    it "returns the versioned install directory" do
      backend = described_class.new("v0.4.2")
      expect(backend.dir).to eq("/opt/vhost-block-backend/v0.4.2")
    end
  end

  describe "#bin_path" do
    it "returns path to vhost-backend binary" do
      backend = described_class.new("v0.4.2")
      expect(backend.bin_path).to eq("/opt/vhost-block-backend/v0.4.2/vhost-backend")
    end
  end

  describe "#init_metadata_path" do
    it "returns path to init-metadata binary" do
      backend = described_class.new("v0.4.2")
      expect(backend.init_metadata_path).to eq("/opt/vhost-block-backend/v0.4.2/init-metadata")
    end
  end

  describe "#archive_path" do
    it "returns path to archive binary" do
      backend = described_class.new("v0.4.2")
      expect(backend.archive_path).to eq("/opt/vhost-block-backend/v0.4.2/archive")
    end
  end

  describe "#dump_metadata_path" do
    it "returns path to dump-metadata binary" do
      backend = described_class.new("v0.4.2")
      expect(backend.dump_metadata_path).to eq("/opt/vhost-block-backend/v0.4.2/dump-metadata")
    end
  end

  describe "#download" do
    let(:backend) { described_class.new("v0.4.2") }
    let(:dir) { "/opt/vhost-block-backend/v0.4.2" }
    let(:temp_tarball) { "/tmp/vhost-backend-v0.4.2.tar.gz" }

    before do
      allow(Arch).to receive(:sym).and_return(:x64)
    end

    it "downloads, extracts, and removes the tarball" do
      expect(backend).to receive(:curl_file)
        .with("https://github.com/ubicloud/ubiblk/releases/download/v0.4.2/ubiblk-x64.tar.gz", temp_tarball)
        .and_return("e7e430f2e722a2d5d7c18a4f609360e003798d481e26da6db380e698ccb079eb")
      expect(FileUtils).to receive(:mkdir_p).with(dir)
      expect(FileUtils).to receive(:cd).with(dir).and_yield
      expect(backend).to receive(:r).with("tar -xzf #{temp_tarball}")
      expect(FileUtils).to receive(:rm_f).with(temp_tarball)

      backend.download
    end

    it "raises an error if the SHA-256 digest is incorrect" do
      expect(backend).to receive(:curl_file).and_return("wrongsha256")
      # mkdir_p, cd, r are NOT called when sha256 fails immediately after download
      expect(FileUtils).not_to receive(:mkdir_p)
      expect { backend.download }.to raise_error("Invalid SHA-256 digest")
    end
  end
end
