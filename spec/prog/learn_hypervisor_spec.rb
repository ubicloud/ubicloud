# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnHypervisor do
  subject(:lh) { described_class.new(Strand.create(prog: "LearnHypervisor", label: "start", stack: [{"subject_id" => vm.id}])) }

  let(:vm_host) { create_vm_host }
  let(:vm) { create_vm(vm_host:) }
  let(:sshable) { lh.vm.vm_host.sshable }

  describe ".assemble" do
    it "creates a strand pointed at the given vm" do
      st = described_class.assemble(vm.id)
      expect(st).to be_a Strand
      expect(st.prog).to eq "LearnHypervisor"
      expect(st.label).to eq "start"
      expect(described_class.new(st).vm.id).to eq vm.id
    end

    it "fails if the vm does not exist" do
      expect {
        described_class.assemble("0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "No existing Vm"
    end
  end

  describe "#start" do
    it "records the CloudHypervisor version in use" do
      expect(sshable).to receive(:_cmd).with("sudo cat /etc/systemd/system/#{vm.inhost_name}.service").and_return(<<~UNIT)
        [Service]
        ExecStart=/opt/cloud-hypervisor/v53.0/cloud-hypervisor -v --api-socket path=/vm/#{vm.inhost_name}/ch.sock
      UNIT
      expect { lh.start }.to exit("msg" => "learned ch 53.0 for #{vm}")
      expect(vm.reload.hypervisor).to eq Hypervisor.first(name: "ch", version: "53.0")
    end

    it "registers a deadline so a stuck strand pages instead of retrying invisibly forever" do
      expect(sshable).to receive(:_cmd).with("sudo cat /etc/systemd/system/#{vm.inhost_name}.service").and_return(<<~UNIT)
        [Service]
        ExecStart=/opt/cloud-hypervisor/v53.0/cloud-hypervisor -v --api-socket path=/vm/#{vm.inhost_name}/ch.sock
      UNIT
      expect(lh).to receive(:register_deadline).with("start", 30 * 60).and_call_original
      expect { lh.start }.to exit("msg" => "learned ch 53.0 for #{vm}")
    end

    it "records qemu if it is in use" do
      expect(sshable).to receive(:_cmd).with("sudo cat /etc/systemd/system/#{vm.inhost_name}.service").and_return(<<~UNIT)
        [Service]
        ExecStart=/usr/bin/qemu-system-x86_64 -enable-kvm
      UNIT
      expect { lh.start }.to exit("msg" => "learned qemu for #{vm}")
      expect(vm.reload.hypervisor).to eq Hypervisor.first(name: "qemu")
    end

    it "exits without erroring if the vm was destroyed before it ran" do
      destroyed_vm_id = vm.id
      vm.destroy
      lh_for_destroyed_vm = described_class.new(Strand.create(prog: "LearnHypervisor", label: "start", stack: [{"subject_id" => destroyed_vm_id}]))
      expect { lh_for_destroyed_vm.start }.to exit("msg" => "exiting as Vm destroyed")
    end

    it "fails if the hypervisor in use cannot be determined" do
      expect(sshable).to receive(:_cmd).with("sudo cat /etc/systemd/system/#{vm.inhost_name}.service").and_return(<<~UNIT)
        [Service]
        ExecStart=/bin/true
      UNIT
      expect { lh.start }.to raise_error RuntimeError, "Could not determine hypervisor in use for #{vm}"
    end
  end
end
