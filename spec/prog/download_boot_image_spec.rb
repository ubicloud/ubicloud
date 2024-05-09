# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DownloadBootImage do
  subject(:dbi) { described_class.new(Strand.new(stack: [{"image_name" => "my-image", "custom_url" => "https://example.com/my-image.raw"}])) }

  let(:sshable) { Sshable.create_with_id }
  let(:vm_host) { VmHost.create(location: "hetzner-hel1") { _1.id = sshable.id } }

  before do
    allow(dbi).to receive_messages(sshable: sshable, vm_host: vm_host)
  end

  describe "#start" do
    it "drains vm host and hops" do
      expect {
        expect { dbi.start }.to hop("wait_draining")
      }.to change { vm_host.reload.allocation_state }.from("unprepared").to("draining")
    end
  end

  describe "#wait_draining" do
    it "waits draining" do
      dataset = instance_double(Sequel::Dataset)
      expect(vm_host).to receive(:vms_dataset).and_return(dataset)
      expect(dataset).to receive(:where).with(boot_image: "my-image").and_return([instance_double(Vm)])
      expect { dbi.wait_draining }.to nap(15)
    end

    it "hops if it's drained" do
      expect(vm_host).to receive(:vms_dataset).and_return(instance_double(Sequel::Dataset, where: []))
      expect(sshable).to receive(:cmd).with("sudo rm -f /var/storage/images/my-image.raw")
      expect { dbi.wait_draining }.to hop("download")
    end
  end

  describe "#download" do
    it "starts to download image if it's not started yet" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'host/bin/download-boot-image my-image https://example.com/my-image.raw' download_my-image", stdin: nil)
      expect { dbi.download }.to nap(15)
    end

    it "generates presigned URL if a custom_url not provided" do
      expect(dbi).to receive(:frame).and_return({"image_name" => "my-image"}).at_least(:once)
      expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, get_presigned_url: "https://minio.example.com/my-image.raw"))
      expect(Config).to receive(:ubicloud_images_blob_storage_certs).and_return("certs").at_least(:once)
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image").and_return("NotStarted")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer 'host/bin/download-boot-image my-image https://minio.example.com/my-image.raw' download_my-image", stdin: "certs")
      expect { dbi.download }.to nap(15)
    end

    it "waits manual intervation if it's failed" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image").and_return("Failed")
      expect { dbi.download }.to raise_error RuntimeError, "Failed to download 'my-image' image on VmHost[#{vm_host.ubid}]"
    end

    it "waits for the download to complete" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image").and_return("InProgess")
      expect { dbi.download }.to nap(15)
    end

    it "hops if it's succeeded" do
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --check download_my-image").and_return("Succeeded")
      expect(sshable).to receive(:cmd).with("common/bin/daemonizer --clean download_my-image")
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
      expect(sshable).to receive(:cmd).with("stat -c %s /var/storage/images/my-image.raw").and_return("2361393152")
      expect { dbi.update_available_storage_space }.to exit({"msg" => "my-image downloaded"})
      expect(sd.reload.available_storage_gib).to eq(32)
    end
  end
end
