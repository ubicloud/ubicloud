# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DownloadBootImage do
  subject(:dbi) { described_class.new(Strand.new(stack: [{"image_name" => "my-image", "custom_url" => "https://example.com/my-image.raw", "version" => "20230303"}])) }

  let(:sshable) { Sshable.create_with_id }
  let(:vm_host) { VmHost.create(location: "hetzner-hel1") { _1.id = sshable.id } }

  before do
    allow(dbi).to receive_messages(sshable: sshable, vm_host: vm_host)
  end

  describe "#start" do
    it "creates database record and hops" do
      expect { dbi.start }.to hop("download")
      expect(BootImage.where(vm_host_id: vm_host.id, name: "my-image", version: "20230303").count).to eq(1)
    end

    it "fails if image already exists" do
      BootImage.create(vm_host_id: vm_host.id, name: "my-image", version: "20230303") { _1.id = vm_host.id }
      expect { dbi.start }.to raise_error RuntimeError, "Image already exists on host"
    end
  end

  describe "#download" do
    it "starts to download image if it's not started yet" do
      params_json = {
        "image_name" => "my-image",
        "url" => "https://example.com/my-image.raw",
        "version" => "20230303",
        "sha256sum" => nil,
        "certs" => nil
      }.to_json
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'host/bin/download-boot-image' download_my-image_20230303", stdin: params_json)
      expect { dbi.download }.to nap(15)
    end

    it "generates presigned URL for github-runners images if a custom_url not provided" do
      params_json = {
        "image_name" => "github-ubuntu-2204",
        "url" => "https://minio.example.com/my-image.raw",
        "version" => "20240422.1.0",
        "sha256sum" => nil,
        "certs" => "certs"
      }.to_json
      expect(dbi).to receive(:frame).and_return({"image_name" => "github-ubuntu-2204", "version" => Config.github_ubuntu_2204_version}).at_least(:once)
      expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, get_presigned_url: "https://minio.example.com/my-image.raw"))
      expect(Config).to receive(:ubicloud_images_blob_storage_certs).and_return("certs").at_least(:once)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_github-ubuntu-2204_20240422.1.0").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'host/bin/download-boot-image' download_github-ubuntu-2204_20240422.1.0", stdin: params_json)
      expect { dbi.download }.to nap(15)
    end

    it "doesn't send a url or a certificate for non-blob-storage images by default" do
      params_json = {
        "image_name" => "my-image",
        "url" => nil,
        "version" => "20230303",
        "sha256sum" => nil,
        "certs" => nil
      }.to_json
      expect(Config).not_to receive(:ubicloud_images_blob_storage_certs)
      expect(dbi).to receive(:frame).and_return({"image_name" => "my-image", "version" => "20230303"}).at_least(:once)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'host/bin/download-boot-image' download_my-image_20230303", stdin: params_json)
      expect { dbi.download }.to nap(15)
    end

    it "waits manual intervation if it's failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("Failed")
      expect { dbi.download }.to raise_error RuntimeError, "Failed to download 'my-image' image on VmHost[#{vm_host.ubid}]"
    end

    it "waits for the download to complete" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("InProgess")
      expect { dbi.download }.to nap(15)
    end

    it "hops if it's succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image_20230303").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean download_my-image_20230303")
      expect { dbi.download }.to hop("update_available_storage_space")
    end
  end

  describe "#update_available_storage_space" do
    it "updates available storage space" do
      sd = StorageDevice.create_with_id(
        vm_host_id: vm_host.id,
        name: "DEFAULT",
        total_storage_gib: 50,
        available_storage_gib: 35,
        enabled: true
      )
      expect(sshable).to receive(:cmd).with("stat -c %s /var/storage/images/my-image-20230303.raw").and_return("2361393152")
      expect { dbi.update_available_storage_space }.to hop("activate_boot_image")
      expect(sd.reload.available_storage_gib).to eq(32)
    end

    it "checks the correct path if version is nil" do
      dbi = described_class.new(Strand.new(stack: [{"image_name" => "my-image", "custom_url" => "https://example.com/my-image.raw", "version" => nil}]))
      allow(dbi).to receive_messages(sshable: sshable, vm_host: vm_host)
      sd = StorageDevice.create_with_id(
        vm_host_id: vm_host.id,
        name: "DEFAULT",
        total_storage_gib: 50,
        available_storage_gib: 35,
        enabled: true
      )
      expect(sshable).to receive(:cmd).with("stat -c %s /var/storage/images/my-image.raw").and_return("2361393152")
      expect { dbi.update_available_storage_space }.to hop("activate_boot_image")
      expect(sd.reload.available_storage_gib).to eq(32)
    end
  end

  describe "#activate_boot_image" do
    it "activates the boot image" do
      dataset = instance_double(Sequel::Dataset)
      expect(BootImage).to receive(:where).with(vm_host_id: vm_host.id, name: "my-image", version: "20230303").and_return(dataset)
      expect(dataset).to receive(:update) do |args|
        expect(args[:activated_at]).to be <= Time.now
      end
      expect { dbi.activate_boot_image }.to exit({"msg" => "image downloaded", "name" => "my-image", "version" => "20230303"})
    end
  end
end
