# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::VmGroup do
  subject(:vg_test) { described_class.new(st) }

  let(:st) { described_class.assemble(boot_images: ["ubuntu-noble", "debian-12"]) }

  describe "#start" do
    it "hops to setup_vms" do
      expect { vg_test.start }.to hop("setup_vms")
    end
  end

  describe "#setup_vms" do
    it "hops to wait_children_ready" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect { vg_test.setup_vms }.to hop("wait_vms")
      vm_images = vg_test.strand.stack.first["vms"].map { Vm[it].boot_image }
      expect(vm_images).to eq(["ubuntu-noble", "debian-12", "ubuntu-noble"])
    end

    it "provisions at least one vm for each boot image" do
      expect(vg_test).to receive(:update_stack).and_call_original
      expect(vg_test).to receive(:frame).and_return({
        "test_slices" => true,
        "boot_images" => ["ubuntu-noble", "ubuntu-jammy", "debian-12", "almalinux-9"]
      }).at_least(:once)
      expect { vg_test.setup_vms }.to hop("wait_vms")
      vm_images = vg_test.strand.stack.first["vms"].map { Vm[it].boot_image }
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
      expect { vg_test.wait_verify_vms }.to hop("verify_host_capacity")
    end

    it "stays in wait_verify_vms" do
      Strand.create(parent_id: st.id, prog: "Test::Vm", label: "start", stack: [{}], lease: Time.now + 10)
      expect { vg_test.wait_verify_vms }.to nap(1)
    end
  end

  describe "#verify_host_capacity" do
    it "hops to verify_vm_host_slices" do
      vm_host = instance_double(VmHost,
        total_cpus: 16,
        total_cores: 8,
        used_cores: 3,
        vms: [instance_double(Vm, cores: 2), instance_double(Vm, cores: 0)],
        slices: [instance_double(VmHostSlice, cores: 1)],
        cpus: [])
      expect(vg_test).to receive_messages(vm_host: vm_host, frame: {"verify_host_capacity" => true})
      expect { vg_test.verify_host_capacity }.to hop("verify_vm_host_slices")
    end

    it "skips if verify_host_capacity is not set" do
      expect(vg_test).to receive(:frame).and_return({"verify_host_capacity" => false})
      expect(vg_test).not_to receive(:vm_host)
      expect { vg_test.verify_host_capacity }.to hop("verify_vm_host_slices")
    end

    it "fails if used cores do not match allocated VMs" do
      vm_host = instance_double(VmHost,
        total_cpus: 16,
        total_cores: 8,
        used_cores: 5,
        vms: [instance_double(Vm, cores: 2), instance_double(Vm, cores: 0)],
        slices: [instance_double(VmHostSlice, cores: 1)],
        cpus: [])
      expect(vg_test).to receive_messages(vm_host: vm_host, frame: {"verify_host_capacity" => true})

      strand = instance_double(Strand)
      allow(vg_test).to receive_messages(strand: strand)
      expect(strand).to receive(:update).with(exitval: {msg: "Host used cores does not match the allocated VMs cores (vm_cores=2, slice_cores=1, spdk_cores=0, used_cores=5)"})

      expect { vg_test.verify_host_capacity }.to hop("failed")
    end
  end

  describe "#verify_vm_host_slices" do
    it "runs tests on vm host slices" do
      expect(vg_test).to receive(:frame).and_return({"test_slices" => true, "vms" => ["111", "222", "333"]}).at_least(:once)
      slice1 = instance_double(VmHostSlice, id: "456")
      slice2 = instance_double(VmHostSlice, id: "789")
      expect(Vm).to receive(:[]).with("111").and_return(instance_double(Vm, vm_host_slice: slice1))
      expect(Vm).to receive(:[]).with("222").and_return(instance_double(Vm, vm_host_slice: slice2))
      expect(Vm).to receive(:[]).with("333").and_return(instance_double(Vm, vm_host_slice: nil))

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
      ps1 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps1", location_id: Location::HETZNER_FSN1_ID).subject
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps2", location_id: Location::HETZNER_FSN1_ID).subject
      expect(vg_test).to receive(:frame).and_return({"subnets" => [ps1.id, ps2.id]}).at_least(:once)
      expect { vg_test.verify_connected_subnets }.to hop("start", "Test::ConnectedSubnets")
    end

    it "runs tests for the second connected subnet" do
      prj = Project.create_with_id(name: "project-1")
      ps1 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps1", location_id: Location::HETZNER_FSN1_ID).subject
      expect(ps1).to receive(:vms).and_return([instance_double(Vm, id: "vm1"), instance_double(Vm, id: "vm2")]).at_least(:once)
      ps2 = Prog::Vnet::SubnetNexus.assemble(prj.id, name: "ps2", location_id: Location::HETZNER_FSN1_ID).subject
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
    before do
      allow(vg_test).to receive(:vm_host).and_return(instance_double(VmHost))
      allow(vg_test.vm_host).to receive(:strand).and_return(instance_double(Strand))
    end

    it "naps if strand is busy" do
      expect(vg_test.vm_host.strand).to receive(:label).and_return("reboot")
      expect { vg_test.wait_reboot }.to nap(20)
    end

    it "runs vm tests if reboot done" do
      expect(vg_test.vm_host.strand).to receive(:label).and_return("wait")
      expect(vg_test.vm_host.strand).to receive(:semaphores).and_return([])
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
    it "returns first VM's host" do
      vm_host = create_vm_host
      vm = create_vm(vm_host_id: vm_host.id)
      expect(vg_test).to receive(:frame).and_return({"vms" => [vm.id]})
      expect(vg_test.vm_host).to eq(vm_host)
    end
  end
end
