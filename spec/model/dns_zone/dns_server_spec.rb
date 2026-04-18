# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe DnsServer do
  subject(:dns_server) { described_class.create(name: "ns.ubicloud.com") }

  describe "#retire_vm" do
    let(:vm1) {
      v = create_vm(name: "vm1")
      Strand.create_with_id(v, prog: "Vm::Nexus", label: "wait")
      v
    }
    let(:vm2) {
      v = create_vm(name: "vm2")
      Strand.create_with_id(v, prog: "Vm::Nexus", label: "wait")
      v
    }

    it "raises if the vm is the only one and force is not set" do
      dns_server.add_vm(vm1)
      expect {
        dns_server.retire_vm(vm1.id)
      }.to raise_error(RuntimeError, "Cannot retire the only VM of DnsServer #{dns_server.name}")
      expect(dns_server.vms_dataset.all).to eq [vm1]
      expect(vm1.destroy_set?).to be false
    end

    it "retires the only vm when force: true is passed" do
      dns_server.add_vm(vm1)
      dns_server.retire_vm(vm1.id, force: true)
      expect(dns_server.vms_dataset.all).to be_empty
      expect(vm1.destroy_set?).to be true
    end

    it "retires a vm when multiple vms are associated" do
      dns_server.add_vm(vm1)
      dns_server.add_vm(vm2)
      dns_server.retire_vm(vm1.id)
      expect(dns_server.vms_dataset.all).to eq [vm2]
      expect(vm1.destroy_set?).to be true
      expect(vm2.destroy_set?).to be false
    end

    it "raises if the vm is not associated with the dns server" do
      dns_server.add_vm(vm1)
      dns_server.add_vm(vm2)
      unrelated_vm = create_vm
      Strand.create_with_id(unrelated_vm, prog: "Vm::Nexus", label: "wait")
      expect {
        dns_server.retire_vm(unrelated_vm.id)
      }.to raise_error(RuntimeError, "VM #{unrelated_vm.ubid} is not associated with DnsServer #{dns_server.name}")
      expect(dns_server.vms_dataset.order(:name).all).to contain_exactly(vm1, vm2)
      expect(unrelated_vm.destroy_set?).to be false
    end
  end
end
