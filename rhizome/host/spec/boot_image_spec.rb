# frozen_string_literal: true

require_relative "../lib/boot_image"
require "openssl"
require "base64"

RSpec.describe BootImage do
  subject(:bi) { described_class.new("ubuntu-jammy", "20240110") }

  describe "#download_boot_image" do
    it "can use an image that's already downloaded" do
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy-20240110.raw").and_return(true)
      expect(bi).not_to receive(:curl_image)
      bi.download(url: "url", ca_path: "ca_path", sha256sum: "sha256sum")
    end

    it "can download an image" do
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy-20240110.raw").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images")
      expect(bi).to receive(:image_ext).with("url").and_return(".img")
      tmp_path = "/var/storage/images/ubuntu-jammy-20240110.img.tmp"
      expect(bi).to receive(:curl_image).with("url", tmp_path, "ca_path")
      expect(bi).to receive(:verify_sha256sum).with(tmp_path, "sha256sum")
      expect(bi).to receive(:convert_image).with(tmp_path, "qcow2")
      expect(FileUtils).to receive(:rm_r).with(tmp_path)

      bi.download(url: "url", ca_path: "ca_path", sha256sum: "sha256sum")
    end
  end

  describe "#image_ext" do
    it "can handle image without query params" do
      url = "http://minio.ubicloud.com:9000/ubicloud-images/ubuntu-22.04-x64.vhd"
      expect(bi.image_ext(url)).to eq(".vhd")
    end

    it "can handle image with query params" do
      url = "http://minio.ubicloud.com:9000/ubicloud-images/ubuntu-22.04-x64.vhd?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=user%2F20240112%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20240112T132931Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=aabbcc"
      expect(bi.image_ext(url)).to eq(".vhd")
    end
  end

  describe "#initial_format" do
    it "fails if initial image has unsupported format" do
      expect { bi.initial_format(".iso") }.to raise_error RuntimeError, "Unsupported boot_image format: .iso"
    end
  end

  describe "#curl_image" do
    it "can curl image without ca_path" do
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/var/storage/images/ubuntu-jammy-20240110.img.tmp")
      end.and_yield
      expect(bi).to receive(:r).with("curl -f -L10 -o /var/storage/images/ubuntu-jammy-20240110.img.tmp url")
      bi.curl_image("url", "/var/storage/images/ubuntu-jammy-20240110.img.tmp", nil)
    end

    it "can curl image with ca_path" do
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/var/storage/images/ubuntu-jammy-20240110.img.tmp")
      end.and_yield
      expect(bi).to receive(:r).with("curl -f -L10 -o /var/storage/images/ubuntu-jammy-20240110.img.tmp url --cacert ca_path")
      bi.curl_image("url", "/var/storage/images/ubuntu-jammy-20240110.img.tmp", "ca_path")
    end
  end

  describe "#verify_sha256sum" do
    it "can verify sha256sum" do
      # Prefer using verifying doubles over normal doubles.
      expect(Digest::SHA256).to receive(:file).with("/var/storage/images/ubuntu-jammy-20240110.img.tmp").and_return(instance_double(Digest::SHA256, hexdigest: "sha256sum"))
      bi.verify_sha256sum("/var/storage/images/ubuntu-jammy-20240110.img.tmp", "sha256sum")
    end

    it "skips verification if sha256sum is empty" do
      expect(Digest::SHA256).not_to receive(:file)
      bi.verify_sha256sum("/var/storage/images/ubuntu-jammy-20240110.img.tmp", nil)
    end
  end

  describe "#convert_image" do
    it "can convert image" do
      expect(bi).to receive(:r).with("qemu-img convert -p -f qcow2 -O raw /var/storage/images/ubuntu-jammy-20240110.img.tmp /var/storage/images/ubuntu-jammy-20240110.raw")
      bi.convert_image("/var/storage/images/ubuntu-jammy-20240110.img.tmp", "qcow2")
    end

    it "does not convert image if it's in raw format already" do
      expect(File).to receive(:rename).with("/var/storage/images/ubuntu-jammy-20240110.img.tmp", "/var/storage/images/ubuntu-jammy-20240110.raw")
      bi.convert_image("/var/storage/images/ubuntu-jammy-20240110.img.tmp", "raw")
    end
  end
end
