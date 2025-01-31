# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::VmGroup do
  subject(:vg_test) { described_class.new(described_class.assemble(boot_images: ["ubuntu-noble", "debian-12"])) }

  describe "#start" do
    it "hops to setup_vms" do
      expect { vg_test.start }.to hop("setup_vms")
    end
  end

  describe "#setup_vms" do
    it "hops to wait_children_ready" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect { vg_test.setup_vms }.to hop("wait_vms")
      vm_images = vg_test.strand.stack.first["vms"].map { Vm[_1].boot_image }
      expect(vm_images).to eq(["ubuntu-noble", "debian-12", "ubuntu-noble"])
    end

    it "provisions at least one vm for each boot image" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect(vg_test).to receive(:frame).and_return({
        "test_slices" => true,
        "boot_images" => ["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"]
      }).at_least(:once)
      expect { vg_test.setup_vms }.to hop("wait_vms")
      vm_images = vg_test.strand.stack.first["vms"].map { Vm[_1].boot_image }
      expect(vm_images).to eq(["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"])
    end

    it "hops to wait_children_ready if test_slices" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect(vg_test).to receive(:frame).and_return({
        "storage_encrypted" => true,
        "test_reboot" => true,
        "test_slices" => true,
        "vms" => [],
        "boot_images" => ["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"]
      }).at_least(:once)
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

  describe "#verify_vms" do
    it "runs tests for the first vm" do
      expect(vg_test).to receive(:frame).and_return({"vms" => ["111", "222"]})
      expect(vg_test).to receive(:bud).with(Prog::Test::Vm, {subject_id: "111"})
      expect(vg_test).to receive(:bud).with(Prog::Test::Vm, {subject_id: "222"})
      expect { vg_test.verify_vms }.to hop("wait_verify_vms")
    end
  end

  describe "#wait_verify_vms" do
    it "hops to hop_wait_verify_vms" do
      expect(vg_test).to receive(:reap)
      expect(vg_test).to receive(:leaf?).and_return(true)
      expect { vg_test.wait_verify_vms }.to hop("verify_vm_host_slices")
    end

    it "stays in wait_verify_vms" do
      expect(vg_test).to receive(:reap)
      expect(vg_test).to receive(:leaf?).and_return(false)
      expect(vg_test).to receive(:donate).and_call_original
      expect { vg_test.wait_verify_vms }.to nap(1)
    end
  end

  describe "#verify_vm_host_slices" do
    it "runs tests on vm host slices" do
      expect(vg_test).to receive(:frame).and_return({"test_slices" => true, "vms" => ["111", "222", "333"]}).at_least(:once)
      slice1 = instance_double(VmHostSlice, id: "456")
      slice2 = instance_double(VmHostSlice, id: "789")
      expect(Vm).to receive(:[]).with("111").and_return(instance_double(Vm, vm_host_slice: slice1))
      expect(Vm).to receive(:[]).with("222").and_return(instance_double(Vm, vm_host_slice: slice2))
      expect(Vm).to receive(:[]).with("333").and_return(instance_double(Vm, vm_host_slice: slice2))

      expect { vg_test.verify_vm_host_slices }.to hop("start", "Test::VmHostSlices")
    end

    it "hops to verify_firewall_rules if tests are done" do
      expect(vg_test).to receive(:frame).and_return({"test_slices" => true})
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified VM Host Slices!"})
      expect { vg_test.verify_vm_host_slices }.to hop("verify_firewall_rules")
    end
  end

  describe "#verify_firewall_rules" do
    it "hops to test_reboot if tests are done" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified Firewall Rules!"})
      expect { vg_test.verify_firewall_rules }.to hop("verify_connected_subnets")
    end

    it "runs tests for the first firewall" do
      subnet = instance_double(PrivateSubnet, firewalls: [instance_double(Firewall, id: "fw_id")])
      expect(PrivateSubnet).to receive(:[]).and_return(subnet)
      expect(vg_test).to receive(:frame).and_return({"subnets" => [subnet]})
      expect { vg_test.verify_firewall_rules }.to hop("start", "Test::FirewallRules")
    end
  end

  describe "#verify_connected_subnets" do
    it "hops to test_reboot if tests are done" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified Connected Subnets!"})
      expect { vg_test.verify_connected_subnets }.to hop("test_reboot")
    end

    it "runs tests for the first connected subnet" do
      prj = Project.create_with_id(name: "project-1")
      ps1 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps1", location: "hetzner-fsn1").subject
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps2", location: "hetzner-fsn1").subject
      expect(vg_test).to receive(:frame).and_return({"subnets" => [ps1.id, ps2.id]}).at_least(:once)
      expect { vg_test.verify_connected_subnets }.to hop("start", "Test::ConnectedSubnets")
    end

    it "runs tests for the second connected subnet" do
      prj = Project.create_with_id(name: "project-1")
      ps1 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps1", location: "hetzner-fsn1").subject
      expect(ps1).to receive(:vms).and_return([instance_double(Vm, id: "vm1"), instance_double(Vm, id: "vm2")]).at_least(:once)
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps2", location: "hetzner-fsn1").subject
      expect(PrivateSubnet).to receive(:[]).and_return(ps1, ps2)
      expect(vg_test).to receive(:frame).and_return({"subnets" => [ps1.id, ps2.id]}).at_least(:once)
      expect { vg_test.verify_connected_subnets }.to hop("start", "Test::ConnectedSubnets")
    end

    it "hops to destroy_resources if tests are done and reboot is not set" do
      expect(vg_test.strand).to receive(:retval).and_return({"msg" => "Verified Connected Subnets!"})
      expect(vg_test).to receive(:frame).and_return({"test_reboot" => false})
      expect { vg_test.verify_connected_subnets }.to hop("destroy_resources")
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
      expect(PrivateSubnet).to receive(:[]).with("subnet_id").and_return(instance_double(PrivateSubnet, incr_destroy: nil, firewalls: []))
      expect { vg_test.destroy_resources }.to hop("wait_resources_destroyed")
    end
  end

  describe "#wait_resources_destroyed" do
    it "hops to verify_purge if all resources are destroyed" do
      allow(vg_test).to receive(:frame).and_return({"vms" => ["vm_id"], "subnets" => ["subnet_id"]}).twice
      expect(Vm).to receive(:[]).with("vm_id").and_return(nil)
      expect(PrivateSubnet).to receive(:[]).with("subnet_id").and_return(nil)

      expect { vg_test.wait_resources_destroyed }.to hop("verify_purge")
    end

    it "naps if all resources are not destroyed yet" do
      allow(vg_test).to receive(:frame).and_return({"vms" => ["vm_id"], "subnets" => ["subnet_id"]}).twice
      expect(Vm).to receive(:[]).with("vm_id").and_return(instance_double(Vm))
      expect { vg_test.wait_resources_destroyed }.to nap(5)
    end
  end

  describe "#verify_purge" do
    let(:sshable) { instance_double(Sshable) }
    let(:spdk_installation) { instance_double(SpdkInstallation, version: "1.0") }
    let(:vm_host) { instance_double(VmHost, sshable: sshable, spdk_installations: [spdk_installation]) }

    before {
      allow(vg_test).to receive(:vm_host).and_return(vm_host)
    }

    it "hops to finish" do
      expect(vg_test).to receive(:verify_vm_dir_purged)
      expect(vg_test).to receive(:verify_storage_files_purged)
      expect(vg_test).to receive(:verify_spdk_artifacts_purged)
      expect { vg_test.verify_purge }.to hop("finish")
    end

    it "verify_vm_dir_purged doesn't fail if /vm is empty" do
      expect(sshable).to receive(:cmd).with("sudo ls -1 /vm").and_return("")
      expect { vg_test.verify_vm_dir_purged }.not_to raise_error
    end

    it "verify_vm_dir_purged fails if /vm is not empty" do
      expect(sshable).to receive(:cmd).with("sudo ls -1 /vm").and_return("vm1\nvm2\n")
      expect(vg_test.strand).to receive(:update).with(exitval: {msg: "VM directory not empty: [\"vm1\", \"vm2\"]"})
      expect { vg_test.verify_vm_dir_purged }.to hop("failed")
    end

    it "verify_storage_files_purged doesn't fail if /var/storage has no disks or vhost sockets" do
      expect(sshable).to receive(:cmd).with("sudo ls -1 /var/storage").and_return("vhost\nimages\n")
      expect(sshable).to receive(:cmd).with("sudo ls -1 /var/storage/vhost").and_return("")
      expect { vg_test.verify_storage_files_purged }.not_to raise_error
    end

    it "verify_storage_files_purged fails if /var/storage has disks" do
      expect(sshable).to receive(:cmd).with("sudo ls -1 /var/storage").and_return("vhost\nimages\ndisk1\ndisk2\n")
      expect(vg_test.strand).to receive(:update).with(exitval: {msg: "VM disks not empty: [\"disk1\", \"disk2\"]"})
      expect { vg_test.verify_storage_files_purged }.to hop("failed")
    end

    it "verify_storage_files_purged fails if /var/storage/vhost has files" do
      expect(sshable).to receive(:cmd).with("sudo ls -1 /var/storage").and_return("vhost\nimages\n")
      expect(sshable).to receive(:cmd).with("sudo ls -1 /var/storage/vhost").and_return("file1\nfile2\n")
      expect(vg_test.strand).to receive(:update).with(exitval: {msg: "vhost directory not empty: [\"file1\", \"file2\"]"})
      expect { vg_test.verify_storage_files_purged }.to hop("failed")
    end

    it "verify_spdk_artifacts_purged doesn't fail if no bdevs or vhost controllers" do
      expect(sshable).to receive(:cmd).with("sudo /opt/spdk-1.0/scripts/rpc.py -s /home/spdk/spdk-1.0.sock bdev_get_bdevs").and_return("[]")
      expect(sshable).to receive(:cmd).with("sudo /opt/spdk-1.0/scripts/rpc.py -s /home/spdk/spdk-1.0.sock vhost_get_controllers").and_return("[]")
      expect { vg_test.verify_spdk_artifacts_purged }.not_to raise_error
    end

    it "verify_spdk_artifacts_purged fails if bdevs are present" do
      expect(sshable).to receive(:cmd).with("sudo /opt/spdk-1.0/scripts/rpc.py -s /home/spdk/spdk-1.0.sock bdev_get_bdevs").and_return("[{\"name\": \"bdev1\", \"size\": 100}]")
      expect(vg_test.strand).to receive(:update).with(exitval: {msg: "SPDK bdevs not empty: [\"bdev1\"]"})
      expect { vg_test.verify_spdk_artifacts_purged }.to hop("failed")
    end

    it "verify_spdk_artifacts_purged fails if vhost controllers are present" do
      expect(sshable).to receive(:cmd).with("sudo /opt/spdk-1.0/scripts/rpc.py -s /home/spdk/spdk-1.0.sock bdev_get_bdevs").and_return("[]")
      expect(sshable).to receive(:cmd).with("sudo /opt/spdk-1.0/scripts/rpc.py -s /home/spdk/spdk-1.0.sock vhost_get_controllers").and_return("[{\"ctrlr\": \"ctrlr1\", \"scsi_target_num\": 0}]")
      expect(vg_test.strand).to receive(:update).with(exitval: {msg: "SPDK vhost controllers not empty: [\"ctrlr1\"]"})
      expect { vg_test.verify_spdk_artifacts_purged }.to hop("failed")
    end
  end

  describe "#finish" do
    it "exits" do
      project = Project.create_with_id(name: "project-1")
      allow(vg_test).to receive(:frame).and_return({"project_id" => project.id})
      expect { vg_test.finish }.to exit({"msg" => "VmGroup tests finished!"})
    end
  end

  describe "#failed" do
    it "naps" do
      expect { vg_test.failed }.to nap(15)
    end
  end

  describe "#vm_host" do
    it "returns the vm_host" do
      sshable = Sshable.create_with_id
      vm_host = VmHost.create(location: "A") { _1.id = sshable.id }
      expect(vg_test.vm_host).to eq(vm_host)
    end
  end
end
