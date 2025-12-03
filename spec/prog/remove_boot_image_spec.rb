# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::RemoveBootImage do
  subject(:rbi) { described_class.new(Strand.new(stack: [{}])) }

  let(:sshable) { vm_host.sshable }
  let(:vm_host) { create_vm_host }
  let(:boot_image) { BootImage.create(name: "ubuntu-jammy", version: "20220202", vm_host_id: vm_host.id, size_gib: 14) }

  before do
    allow(rbi).to receive(:boot_image).and_return(boot_image)
    allow(boot_image).to receive(:vm_host).and_return(vm_host)
  end

  describe "#start" do
    it "deactivates and hops to wait_volumes" do
      expect { rbi.start }.to hop("wait_volumes")
      expect(boot_image.reload.activated_at).to be_nil
    end
  end

  describe "#wait_volumes" do
    it "hops to remove_volumes if all volumes are removed" do
      expect { rbi.wait_volumes }.to hop("remove")
    end

    it "waits for volumes to be removed" do
      expect(boot_image).to receive(:vm_storage_volumes).and_return([1])
      expect { rbi.wait_volumes }.to nap(30)
    end
  end

  describe "#remove" do
    it "removes image and pops" do
      expect(sshable).to receive(:_cmd).with("sudo rm -rf /var/storage/images/ubuntu-jammy-20220202.raw")
      expect { rbi.remove }.to hop("update_database")
    end

    it "can remove unversioned image" do
      boot_image.update(version: nil)
      expect(sshable).to receive(:_cmd).with("sudo rm -rf /var/storage/images/ubuntu-jammy.raw")
      expect { rbi.remove }.to hop("update_database")
    end
  end

  describe "#update_database" do
    it "updates storage and destroys boot image" do
      boot_image.id
      storage_device = StorageDevice.create(vm_host_id: vm_host.id, name: "DEFAULT", available_storage_gib: 100, total_storage_gib: 200)
      expect { rbi.update_database }.to exit({"msg" => "Boot image was removed."})
      expect(BootImage[boot_image.id]).to be_nil
      expect(storage_device.reload.available_storage_gib).to eq(114)
    end
  end
end
