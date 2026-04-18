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

  describe "#run_commands_on_all_vms" do
    let(:vm1) {
      v = create_vm(name: "ubi-1")
      Sshable.create_with_id(v.id, unix_user: "root", host: "host-1")
      v
    }
    let(:vm2) {
      v = create_vm(name: "ubi-2")
      Sshable.create_with_id(v.id, unix_user: "root", host: "host-2")
      v
    }
    let(:commands) {
      [
        "zone-abort tahcloud.io",
        "zone-begin tahcloud.io",
        "zone-set tahcloud.io foo 10 A 1.2.3.4",
        "zone-unset tahcloud.io bar 10 A 5.6.7.8",
        "zone-commit tahcloud.io",
      ]
    }

    it "does nothing when no vms are associated" do
      expect { dns_server.run_commands_on_all_vms(commands) }.not_to raise_error
    end

    it "runs commands on every associated vm via stdin" do
      dns_server.add_vm(vm1)
      dns_server.add_vm(vm2)
      dns_server.vms.each do |vm|
        expect(vm.sshable).to receive(:_cmd).with("sudo -u knot knotc", stdin: commands.join("\n")).and_return("OK\nOK\nOK\nOK\nOK")
      end
      dns_server.run_commands_on_all_vms(commands)
    end

    it "ignores 'no active transaction' on the first command" do
      dns_server.add_vm(vm1)
      expect(dns_server.vms.first.sshable).to receive(:_cmd).and_return("no active transaction\nOK\nOK\nOK\nOK")
      expect { dns_server.run_commands_on_all_vms(commands) }.not_to raise_error
    end

    it "does not ignore 'no active transaction' on non-first commands" do
      dns_server.add_vm(vm1)
      expect(dns_server.vms.first.sshable).to receive(:_cmd).and_return("OK\nno active transaction\nOK\nOK\nOK")
      expect {
        dns_server.run_commands_on_all_vms(commands)
      }.to raise_error(RuntimeError, "Rectify failed on #{dns_server}. Command: #{commands[1]}. Output: no active transaction")
    end

    it "ignores 'such record already exists in zone' for zone-set commands" do
      dns_server.add_vm(vm1)
      expect(dns_server.vms.first.sshable).to receive(:_cmd).and_return("OK\nOK\nsuch record already exists in zone\nOK\nOK")
      expect { dns_server.run_commands_on_all_vms(commands) }.not_to raise_error
    end

    it "ignores 'no such record in zone found' for zone-unset commands" do
      dns_server.add_vm(vm1)
      expect(dns_server.vms.first.sshable).to receive(:_cmd).and_return("OK\nOK\nOK\nno such record in zone found\nOK")
      expect { dns_server.run_commands_on_all_vms(commands) }.not_to raise_error
    end

    it "raises when a zone-set command returns 'no such record in zone found'" do
      dns_server.add_vm(vm1)
      expect(dns_server.vms.first.sshable).to receive(:_cmd).and_return("OK\nOK\nno such record in zone found\nOK\nOK")
      expect {
        dns_server.run_commands_on_all_vms(commands)
      }.to raise_error(RuntimeError, "Rectify failed on #{dns_server}. Command: #{commands[2]}. Output: no such record in zone found")
    end

    it "raises when a zone-unset command returns 'such record already exists in zone'" do
      dns_server.add_vm(vm1)
      expect(dns_server.vms.first.sshable).to receive(:_cmd).and_return("OK\nOK\nOK\nsuch record already exists in zone\nOK")
      expect {
        dns_server.run_commands_on_all_vms(commands)
      }.to raise_error(RuntimeError, "Rectify failed on #{dns_server}. Command: #{commands[3]}. Output: such record already exists in zone")
    end

    it "raises on any other unexpected output" do
      dns_server.add_vm(vm1)
      expect(dns_server.vms.first.sshable).to receive(:_cmd).and_return("OK\nOK\nOK\nOK\nboom")
      expect {
        dns_server.run_commands_on_all_vms(commands)
      }.to raise_error(RuntimeError, "Rectify failed on #{dns_server}. Command: #{commands[4]}. Output: boom")
    end

    it "raises without contacting the second vm when the first vm fails" do
      dns_server.add_vm(vm1)
      dns_server.add_vm(vm2)
      first_vm, second_vm = dns_server.vms
      expect(first_vm.sshable).to receive(:_cmd).and_return("error\nOK\nOK\nOK\nOK")
      expect(second_vm.sshable).not_to receive(:_cmd)
      expect {
        dns_server.run_commands_on_all_vms(commands)
      }.to raise_error(RuntimeError, "Rectify failed on #{dns_server}. Command: #{commands[0]}. Output: error")
    end
  end
end
