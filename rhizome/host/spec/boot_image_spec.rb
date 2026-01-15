# frozen_string_literal: true

require_relative "../lib/boot_image"
require "openssl"
require "base64"

RSpec.describe BootImage do
  subject(:bi) { described_class.new("ubuntu-jammy", "20240110") }

  describe "#download" do
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
      expect(bi).to receive(:curl_image).with("url", tmp_path, "ca_path").and_return("returned_sha256sum")
      expect(bi).to receive(:verify_sha256sum).with("returned_sha256sum", "sha256sum")
      expect(bi).to receive(:convert_image).with(tmp_path, "qcow2")
      expect(FileUtils).to receive(:rm_r).with(tmp_path)

      bi.download(url: "url", ca_path: "ca_path", sha256sum: "sha256sum")
    end

    it "can download an image with htcat" do
      expect(File).to receive(:exist?).with("/var/storage/images/ubuntu-jammy-20240110.raw").and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with("/var/storage/images")
      expect(bi).to receive(:image_ext).with("url").and_return(".img")
      tmp_path = "/var/storage/images/ubuntu-jammy-20240110.img.tmp"
      expect(bi).to receive(:htcat_image).with("url", tmp_path).and_return("returned_sha256sum")
      expect(bi).to receive(:verify_sha256sum).with("returned_sha256sum", "sha256sum")
      expect(bi).to receive(:convert_image).with(tmp_path, "qcow2")
      expect(FileUtils).to receive(:rm_r).with(tmp_path)

      bi.download(url: "url", ca_path: "ca_path", sha256sum: "sha256sum", use_htcat: true)
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

      expect(bi).to receive(:r).with(
        "bash -c 'curl -f -L10 url | tee >(openssl dgst -sha256) > /var/storage/images/ubuntu-jammy-20240110.img.tmp'"
      ).and_return("SHA2-256(stdin)= 81fae9cc21e2b1e3a9a4526c7dad3131b668e346c580702235ad4d02645d9455\n")

      expect(
        bi.curl_image("url", "/var/storage/images/ubuntu-jammy-20240110.img.tmp", nil)
      ).to eq("81fae9cc21e2b1e3a9a4526c7dad3131b668e346c580702235ad4d02645d9455")
    end

    it "can curl image with ca_path" do
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/var/storage/images/ubuntu-jammy-20240110.img.tmp")
      end.and_yield

      expect(bi).to receive(:r).with(
        "bash -c 'curl -f -L10 url --cacert ca_path | tee >(openssl dgst -sha256) > /var/storage/images/ubuntu-jammy-20240110.img.tmp'"
      ).and_return("SHA2-256(stdin)= 81fae9cc21e2b1e3a9a4526c7dad3131b668e346c580702235ad4d02645d9455\n")

      bi.curl_image("url", "/var/storage/images/ubuntu-jammy-20240110.img.tmp", "ca_path")
    end
  end

  describe "#htcat_image" do
    it "can htcat image with sha256 checksum" do
      expect(File).to receive(:open) do |path, *_args|
        expect(path).to eq("/var/storage/images/ubuntu-jammy-20240110.img.tmp")
      end.and_yield

      expect(bi).to receive(:r).with(
        "bash -c 'htcat -parallelism=12 -max-fragment-size=32 URL | tee >(openssl dgst -sha256) > /var/storage/images/ubuntu-jammy-20240110.img.tmp'"
      ).and_return("SHA2-256(stdin)= 81fae9cc21e2b1e3a9a4526c7dad3131b668e346c580702235ad4d02645d9455\n")

      bi.htcat_image("URL", "/var/storage/images/ubuntu-jammy-20240110.img.tmp")
    end
  end

  describe "#verify_sha256sum" do
    it "succeeds if sha256 sums match" do
      expect { bi.verify_sha256sum("sha256sum", "sha256sum") }.not_to raise_error
    end

    it "fails if sha256 sums do not match" do
      expect { bi.verify_sha256sum("sha256sum", "invalid") }.to raise_error(RuntimeError, "Invalid SHA256 sum.")
    end

    it "succeeds if expected sha256 sum is nil" do
      expect { bi.verify_sha256sum("sha256sum", nil) }.not_to raise_error
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
