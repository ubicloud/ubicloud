# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Storage::RemoveSpdk do
  subject(:remove_spdk) {
    described_class.new(described_class.assemble(spdk_installation.id))
  }

  let(:vm_host) { create_vm_host }
  let(:spdk_installation) {
    SpdkInstallation.create(version: "v23.09-ubi-0.2", allocation_weight: 100, vm_host_id: vm_host.id)
  }
  let!(:second_spdk) {
    SpdkInstallation.create(version: "v23.09-ubi-0.3", allocation_weight: 100, vm_host_id: vm_host.id)
  }

  def sshable
    remove_spdk.spdk_installation.vm_host.sshable
  end

  describe "#start" do
    it "hops to wait_volumes" do
      expect { remove_spdk.start }.to hop("wait_volumes")
      expect(spdk_installation.reload.allocation_weight).to eq(0)
    end

    it "fails if this is the last storage backend" do
      second_spdk.destroy
      expect { remove_spdk.start }.to raise_error RuntimeError, "Can't remove the last storage backend from the host"
    end

    it "does not fail if there are other storage backends" do
      second_spdk.destroy
      VhostBlockBackend.create(vm_host_id: vm_host.id, version: "v1", allocation_weight: 100)
      expect { remove_spdk.start }.to hop("wait_volumes")
    end
  end

  describe "#wait_volumes" do
    before { spdk_installation.update(allocation_weight: 0) }

    it "waits until all volumes using the installation are destroyed" do
      VmStorageVolume.create(
        vm_id: create_vm(vm_host:).id,
        boot: true,
        size_gib: 10,
        disk_index: 0,
        use_bdev_ubi: false,
        spdk_installation_id: spdk_installation.id
      )
      expect { remove_spdk.wait_volumes }.to nap(30)
    end

    it "hops to remove_spdk if no volumes are using the installation" do
      expect { remove_spdk.wait_volumes }.to hop("remove_spdk")
    end
  end

  describe "#remove_spdk" do
    before { spdk_installation.update(allocation_weight: 0) }

    it "hops to update_database" do
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-spdk remove v23.09-ubi-0.2")
      expect { remove_spdk.remove_spdk }.to hop("update_database")
    end
  end

  describe "#update_database" do
    before do
      spdk_installation.update(allocation_weight: 0)
      vm_host.update(total_hugepages_1g: 4, used_hugepages_1g: 4)
    end

    it "updates the database and exits" do
      expect { remove_spdk.update_database }.to exit({"msg" => "SPDK installation was removed"})
      expect(spdk_installation.exists?).to be false
      expect(vm_host.reload.used_hugepages_1g).to eq(2)
    end
  end
end
