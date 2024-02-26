# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::VmGroup do
  subject(:vg_test) { described_class.new(described_class.assemble) }

  describe "#start" do
    it "hops to setup_vms" do
      expect { vg_test.start }.to hop("setup_vms")
    end
  end

  describe "#setup_vms" do
    it "hops to wait_children_ready" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect { vg_test.setup_vms }.to hop("wait_vms")
    end
  end

  describe "#wait_vms" do
    it "hops to verify_vms if vms are ready" do
      expect(vg_test).to receive(:frame).and_return({"vms" => ["111"]})
      expect(Vm).to receive(:[]).with("111").and_return(instance_double(Vm, display_state: "running"))
      expect { vg_test.wait_vms }.to hop("verify_vms")
    end

    it "naps if vms are not running" do
      expect(vg_test).to receive(:frame).and_return({"vms" => ["111"]})
      expect(Vm).to receive(:[]).with("111").and_return(instance_double(Vm, display_state: "creating"))
      expect { vg_test.wait_vms }.to nap(10)
    end
  end

  describe "#children_ready" do
    it "hops to wait_subtests" do
      vm = Vm.create_with_id(unix_user: "u", public_key: "k", name: "n", location: "l", boot_image: "i", family: "f", cores: 2)
      Sshable.create { _1.id = vm.id }
      expect(vg_test).to receive(:verify_storage_volumes)
      allow(vg_test).to receive(:frame).and_return({"vms" => [vm.id]})
      expect { vg_test.children_ready }.to hop("wait_subtests", "Test::VmGroup")
    end
  end

  describe "#verify_vms" do
    it "runs tests for the first vm" do
      expect(vg_test).to receive(:frame).and_return({"vms" => ["111"]})
      expect { vg_test.verify_vms }.to hop("start", "Test::Vm")
    end
  end

  describe "#verify_storage_volumes" do
    let(:sshable) { Sshable.create_with_id }
    let(:host) { VmHost.create(location: "x") { _1.id = sshable.id } }
    let(:vm) {
      Vm.create_with_id(unix_user: "x", public_key: "x", name: "x", family: "x", cores: 2, location: "x", boot_image: "x", vm_host_id: host.id)
    }

    before do
      allow(vg_test).to receive(:host).and_return(host)
      allow(host).to receive(:sshable).and_return(sshable)

      si = SpdkInstallation.create(
        version: "v1",
        allocation_weight: 100,
        vm_host_id: host.id
      ) { _1.id = host.id }
      dev_1 = StorageDevice.create(name: "nvme0",
        available_storage_gib: 100,
        total_storage_gib: 100,
        vm_host_id: host.id) { _1.id = StorageDevice.generate_uuid }
      dev_2 = StorageDevice.create(name: "DEFAULT",
        available_storage_gib: 100,
        total_storage_gib: 100,
        vm_host_id: host.id) { _1.id = host.id }
      [
        VmStorageVolume.create_with_id(
          vm_id: vm.id, size_gib: 5, disk_index: 0, boot: true,
          spdk_installation_id: si.id,
          storage_device_id: dev_1.id
        ),
        VmStorageVolume.create_with_id(
          vm_id: vm.id, size_gib: 15, disk_index: 1, boot: false,
          spdk_installation_id: si.id,
          storage_device_id: dev_2.id
        )
      ]
    end

    it "verifies sizes of all storage volumes" do
      allow(sshable).to receive(:cmd).with("sudo wc --bytes /var/storage/devices/nvme0/#{vm.inhost_name}/0/disk.raw").and_return("5368709120 /path\n")
      allow(sshable).to receive(:cmd).with("sudo wc --bytes /var/storage/#{vm.inhost_name}/1/disk.raw").and_return("16106127360 /path\n")
      expect { vg_test.verify_storage_volumes(vm) }.not_to raise_error
    end

    it "fails if file size is too small" do
      allow(sshable).to receive(:cmd).with("sudo wc --bytes /var/storage/devices/nvme0/#{vm.inhost_name}/0/disk.raw").and_return("5368709110 /path\n")
      expect { vg_test.verify_storage_volumes(vm) }.to raise_error RuntimeError
    end
  end

  describe "#wait_subtests" do
    it "hops to destroy_vms if children idle and not test_reboot" do
      expect(vg_test).to receive(:children_idle).and_return(true)
    end

    it "hops to destroy_resources if tests are done and not test_reboot" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified VM!"})
      expect(vg_test).to receive(:frame).and_return({"test_reboot" => false})
      expect { vg_test.verify_vms }.to hop("destroy_resources")
    end

    it "hops to test_reboot if tests are done and test_reboot" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified VM!"})
      expect(vg_test).to receive(:frame).and_return({"test_reboot" => true})
      expect { vg_test.verify_vms }.to hop("test_reboot")
    end
  end

  describe "#test_reboot" do
    it "hops to wait_reboot" do
      expect(vg_test).to receive(:vm_host).and_return(instance_double(VmHost)).twice
      expect(vg_test.vm_host).to receive(:incr_reboot).with(no_args)
      expect { vg_test.test_reboot }.to hop("wait_reboot")
    end
  end

  describe "#wait_reboot" do
    let(:st) { instance_double(Strand) }

    before do
      allow(vg_test).to receive(:vm_host).and_return(instance_double(VmHost))
      allow(vg_test.vm_host).to receive(:strand).and_return(st)
    end

    it "naps if strand is busy" do
      expect(st).to receive(:label).and_return("reboot")
      expect { vg_test.wait_reboot }.to nap(20)
    end

    it "runs vm tests if reboot done" do
      expect(st).to receive(:label).and_return("wait")
      expect(st).to receive(:semaphores).and_return([])
      expect { vg_test.wait_reboot }.to hop("verify_vms")
    end
  end

  describe "#destroy_resources" do
    it "hops to wait_resources_destroyed" do
      allow(vg_test).to receive(:frame).and_return({"vms" => ["vm_id"], "subnets" => ["subnet_id"]}).twice
      expect(Vm).to receive(:[]).with("vm_id").and_return(instance_double(Vm, incr_destroy: nil))
      expect(PrivateSubnet).to receive(:[]).with("subnet_id").and_return(instance_double(PrivateSubnet, incr_destroy: nil))
      expect { vg_test.destroy_resources }.to hop("wait_resources_destroyed")
    end
  end

  describe "#wait_resources_destroyed" do
    it "hops to finish if all resources are destroyed" do
      allow(vg_test).to receive(:frame).and_return({"vms" => ["vm_id"], "subnets" => ["subnet_id"]}).twice
      expect(Vm).to receive(:[]).with("vm_id").and_return(nil)
      expect(PrivateSubnet).to receive(:[]).with("subnet_id").and_return(nil)

      expect { vg_test.wait_resources_destroyed }.to hop("finish")
    end

    it "naps if all resources are not destroyed yet" do
      allow(vg_test).to receive(:frame).and_return({"vms" => ["vm_id"], "subnets" => ["subnet_id"]}).twice
      expect(Vm).to receive(:[]).with("vm_id").and_return(instance_double(Vm))
      expect { vg_test.wait_resources_destroyed }.to nap(5)
    end
  end

  describe "#finish" do
    it "exits" do
      project = Project.create_with_id(name: "project 1", provider: "hetzner")
      allow(vg_test).to receive(:frame).and_return({"project_id" => project.id})
      expect { vg_test.finish }.to exit({"msg" => "VmGroup tests finished!"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { vg_test.failed }.to nap(15)
    end
  end

  describe "#host" do
    it "returns the host" do
      sshable = Sshable.create_with_id
      host = VmHost.create(location: "A") { _1.id = sshable.id }
      expect(vg_test.host).to eq(host)
    end
  end

  describe "#vm_host" do
    it "returns first VM's host" do
      sshable = Sshable.create_with_id
      vm_host = VmHost.create(location: "A") { _1.id = sshable.id }
      vm = Vm.create_with_id(unix_user: "root", public_key: "", name: "xyz", location: "a", boot_image: "b", family: "z", cores: 1, vm_host_id: vm_host.id)
      expect(vg_test).to receive(:frame).and_return({"vms" => [vm.id]})
      expect(vg_test.vm_host).to eq(vm_host)
    end
  end
end
