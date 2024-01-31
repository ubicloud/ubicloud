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
      expect(vm_host).to receive(:vms).and_return([instance_double(Vm)])
      expect { dbi.wait_draining }.to nap(15)
    end

    it "hops if it's drained" do
      expect(vm_host).to receive(:vms).and_return([])
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
      expect { dbi.download }.to hop("learn_storage")
    end
  end

  describe "#learn_storage" do
    it "starts a number of sub-programs" do
      expect(dbi).to receive(:bud).with(Prog::LearnStorage)
      expect { dbi.learn_storage }.to hop("wait_learn_storage")
    end
  end

  describe "#wait_learn_storage" do
    it "updates the vm_host record from the finished programs" do
      expect(vm_host).to receive(:update).with(total_storage_gib: 300, available_storage_gib: 500)
      expect(dbi).to receive(:reap).and_return([
        instance_double(Strand, prog: "LearnStorage", exitval: {"total_storage_gib" => 300, "available_storage_gib" => 500}),
        instance_double(Strand, prog: "ArbitraryOtherProg")
      ])

      expect { dbi.wait_learn_storage }.to hop("activate_host")
    end

    it "crashes if an expected field is not set for LearnStorage" do
      expect(dbi).to receive(:reap).and_return([instance_double(Strand, prog: "LearnStorage", exitval: {})])
      expect { dbi.wait_learn_storage }.to raise_error KeyError, "key not found: \"total_storage_gib\""
    end

    it "donates to children if they are not exited yet" do
      expect(dbi).to receive(:reap).and_return([])
      expect(dbi).to receive(:leaf?).and_return(false)
      expect(dbi).to receive(:donate).and_call_original
      expect { dbi.wait_learn_storage }.to nap(0)
    end
  end

  describe "#activate_host" do
    it "activates vm host again" do
      expect(sshable).to receive(:cmd).with("ls /var/storage/images/my-image.raw")
      expect {
        expect { dbi.activate_host }.to exit({"msg" => "my-image downloaded"})
      }.to change { vm_host.reload.allocation_state }.from("unprepared").to("accepting")
    end
  end
end
