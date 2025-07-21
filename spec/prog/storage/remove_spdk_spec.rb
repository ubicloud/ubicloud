# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::RemoveSpdk do
  subject(:remove_spdk) {
    described_class.new(described_class.assemble(
      "2f7071b5-3a0e-85da-9727-8a32fbcbd94b"
    ))
  }

  let(:spdk_version) { "v23.09-ubi-0.2" }
  let(:sshable) {
    instance_double(Sshable)
  }
  let(:vm_host) {
    vmh = instance_double(VmHost)
    allow(vmh).to receive_messages(
      sshable: sshable,
      spdk_installations: ["spdk_1", "spdk_2"],
      id: "d05761b4-2cad-8b71-a300-ded6153e02b2"
    )
    vmh
  }
  let(:spdk_installation) {
    si = instance_double(SpdkInstallation)
    allow(si).to receive_messages(vm_host: vm_host, version: spdk_version)
    si
  }

  before do
    allow(remove_spdk).to receive(:spdk_installation).and_return(spdk_installation)
  end

  describe "#start" do
    it "hops to wait_volumes" do
      expect(spdk_installation).to receive(:update).with(allocation_weight: 0)
      expect { remove_spdk.start }.to hop("wait_volumes")
    end

    it "fails if this is the last storage backend" do
      expect(vm_host).to receive(:spdk_installations).and_return(["spdk_1"])
      expect(vm_host).to receive(:vhost_block_backends).and_return([])
      expect { remove_spdk.start }.to raise_error RuntimeError, "Can't remove the last storage backend from the host"
    end

    it "does not fail if there are other storage backends" do
      expect(vm_host).to receive(:spdk_installations).and_return(["spdk_1"])
      expect(vm_host).to receive(:vhost_block_backends).and_return(["vhost_backend"])
      expect(spdk_installation).to receive(:update).with(allocation_weight: 0)
      expect { remove_spdk.start }.to hop("wait_volumes")
    end
  end

  describe "#wait_volumes" do
    it "waits until all volumes using the installation are destroyed" do
      expect(spdk_installation).to receive(:vm_storage_volumes).and_return([:vm])
      expect { remove_spdk.wait_volumes }.to nap(30)
    end

    it "hops to remove_spdk if no volumes are using the installation" do
      expect(spdk_installation).to receive(:vm_storage_volumes).and_return([])
      expect { remove_spdk.wait_volumes }.to hop("remove_spdk")
    end
  end

  describe "#remove_spdk" do
    it "hops to update_database" do
      expect(sshable).to receive(:cmd).with("sudo host/bin/setup-spdk remove v23.09-ubi-0.2")
      expect { remove_spdk.remove_spdk }.to hop("update_database")
    end
  end

  describe "#update_database" do
    it "updates the database and exits" do
      expect(spdk_installation).to receive(:hugepages).and_return(2)
      expect(spdk_installation).to receive(:destroy)
      expect { remove_spdk.update_database }.to exit({"msg" => "SPDK installation was removed"})
    end
  end
end
