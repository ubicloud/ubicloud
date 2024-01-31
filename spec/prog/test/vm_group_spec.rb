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

  describe "#verify_vms" do
    it "runs tests for the first vm" do
      expect(vg_test).to receive(:frame).and_return({"vms" => ["111"]})
      expect { vg_test.verify_vms }.to hop("start", "Test::Vm")
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
