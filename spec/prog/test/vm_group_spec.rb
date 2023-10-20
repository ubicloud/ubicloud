# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Test::VmGroup do
  subject(:vg_test) {
    described_class.new(described_class.assemble)
  }

  describe "#start" do
    it "hops to setup_vms" do
      expect { vg_test.start }.to hop("setup_vms", "Test::VmGroup")
    end
  end

  describe "#setup_vms" do
    it "hops to wait_children_ready" do
      expect { vg_test.setup_vms }.to hop("wait_children_ready", "Test::VmGroup")
    end
  end

  describe "#wait_children_ready" do
    it "hops to children_ready if children idle" do
      expect(vg_test).to receive(:children_idle).and_return(true)
      expect { vg_test.wait_children_ready }.to hop("children_ready", "Test::VmGroup")
    end

    it "donates if children not idle" do
      expect(vg_test).to receive(:children_idle).and_return(false)
      expect { vg_test.wait_children_ready }.to nap(0)
    end
  end

  describe "#children_ready" do
    it "hops to wait_subtests" do
      vm = Vm.create_with_id(unix_user: "u", public_key: "k", name: "n", location: "l", boot_image: "i", family: "f", cores: 2)
      Sshable.create { _1.id = vm.id }
      allow(vg_test).to receive(:frame).and_return({"vms" => [vm.id]})
      expect { vg_test.children_ready }.to hop("wait_subtests", "Test::VmGroup")
    end
  end

  describe "#wait_subtests" do
    it "hops to destroy_vms if children idle and not test_reboot" do
      expect(vg_test).to receive(:children_idle).and_return(true)
      expect(vg_test).to receive(:frame).and_return({"test_reboot" => false})
      expect { vg_test.wait_subtests }.to hop("destroy_vms", "Test::VmGroup")
    end

    it "hops to test_reboot if children idle and test_reboot" do
      expect(vg_test).to receive(:children_idle).and_return(true)
      expect(vg_test).to receive(:frame).and_return({"test_reboot" => true})
      expect { vg_test.wait_subtests }.to hop("test_reboot", "Test::VmGroup")
    end

    it "donates if children not idle" do
      expect(vg_test).to receive(:children_idle).and_return(false)
      expect { vg_test.wait_subtests }.to nap(0)
    end
  end

  describe "#test_reboot" do
    it "hops to wait_reboot" do
      host = instance_double(VmHost)
      expect(vg_test).to receive(:host).and_return(host)
      expect(host).to receive(:incr_reboot).with(no_args)
      expect { vg_test.test_reboot }.to hop("wait_reboot", "Test::VmGroup")
    end
  end

  describe "#wait_reboot" do
    let(:st) {
      instance_double(Strand)
    }

    before do
      host = instance_double(VmHost)
      allow(vg_test).to receive(:host).and_return(host)
      allow(host).to receive(:strand).and_return(st)
    end

    it "naps if strand is busy" do
      expect(st).to receive(:label).and_return("reboot")
      expect { vg_test.wait_reboot }.to nap(30)
    end

    it "runs vm tests if reboot done" do
      expect(st).to receive(:label).and_return("wait")
      expect(st).to receive(:semaphores).and_return([])
      expect { vg_test.wait_reboot }.to hop("wait_children_ready", "Test::VmGroup")
    end
  end

  describe "#destroy_vms" do
    it "hops to wait_vms_destroyed" do
      vm = Vm.create_with_id(unix_user: "u", public_key: "k", name: "n", location: "l", boot_image: "i", family: "f", cores: 2)
      Sshable.create { _1.id = vm.id }
      Strand.create(prog: "Vm::Nexus", label: "wait") { _1.id = vm.id }
      allow(vg_test).to receive(:frame).and_return({"vms" => [vm.id]})
      expect { vg_test.destroy_vms }.to hop("wait_vms_destroyed", "Test::VmGroup")
    end
  end

  describe "#wait_vms_destroyed" do
    it "hops to destroy_subnets if children idle" do
      expect(vg_test).to receive(:children_idle).and_return(true)
      expect { vg_test.wait_vms_destroyed }.to hop("destroy_subnets", "Test::VmGroup")
    end

    it "donates if children not idle" do
      expect(vg_test).to receive(:children_idle).and_return(false)
      expect { vg_test.wait_vms_destroyed }.to nap(0)
    end
  end

  describe "#destroy_subnets" do
    it "hops to wait_subnets_destroyed" do
      subnet = PrivateSubnet.create_with_id(net6: "1::/64", net4: "192.168.1.1", name: "n", location: "l")
      Strand.create(prog: "Vnet::SubnetNexus", label: "wait") { _1.id = subnet.id }
      allow(vg_test).to receive(:frame).and_return({"subnets" => [subnet.id]})
      expect { vg_test.destroy_subnets }.to hop("wait_subnets_destroyed", "Test::VmGroup")
    end
  end

  describe "#wait_subnets_destroyed" do
    it "hops to finish if children idle" do
      expect(vg_test).to receive(:children_idle).and_return(true)
      expect { vg_test.wait_subnets_destroyed }.to hop("finish", "Test::VmGroup")
    end

    it "donates if children not idle" do
      expect(vg_test).to receive(:children_idle).and_return(false)
      expect { vg_test.wait_subnets_destroyed }.to nap(0)
    end
  end

  describe "#finish" do
    it "exits" do
      project = Project.create_with_id(name: "project 1", provider: "hetzner")
      allow(vg_test).to receive(:frame).and_return({"project_id" => project.id})
      expect { vg_test.finish }.to exit({"msg" => "VmGroup tests finished!"})
    end
  end

  describe "#children_idle" do
    it "returns true if no children" do
      st = Strand.create_with_id(prog: "Prog", label: "label")
      allow(vg_test).to receive(:strand).and_return(st)
      expect(vg_test.children_idle).to be(true)
    end
  end

  describe "#host" do
    it "returns first VM's host" do
      sshable = Sshable.create_with_id
      host = VmHost.create(location: "A") { _1.id = sshable.id }
      vm = Vm.create_with_id(unix_user: "root", public_key: "", name: "xyz", location: "a", boot_image: "b", family: "z", cores: 1, vm_host_id: host.id)
      expect(vg_test).to receive(:frame).and_return({"vms" => [vm.id]})
      expect(vg_test.host).to eq(host)
    end
  end
end
