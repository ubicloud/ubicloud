# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Vm::UpdateIpv6 do
  subject(:pr) {
    described_class.new(Strand.new)
  }

  let(:vm) {
    instance_double(Vm,
      inhost_name: "test",
      storage_secrets: "storage_secrets",
      nics: [instance_double(Nic,
        private_subnet: instance_double(
          PrivateSubnet,
          net4: NetAddr::IPv4Net.parse("1.0.0.0/8")
        ),
        ubid_to_tap_name: "ubid_to_tap_name")],
      name: "test",
      vm_host_id: 1)
  }

  let(:vm_host) {
    instance_double(VmHost, sshable: instance_double(Sshable, host: "1.1.1.1"), ip6_random_vm_network: NetAddr::IPv6Net.parse("2001:0::"))
  }

  before do
    allow(pr).to receive(:vm).and_return(vm)
  end

  it "returns vm_host" do
    expect(VmHost).to receive(:[]).with(1).and_return(vm_host)
    expect(pr.vm_host).to eq(vm_host)
  end

  it "stops services and cleans up namespace" do
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm_host.sshable).to receive(:cmd).with("sudo systemctl stop test.service")
    expect(vm_host.sshable).to receive(:cmd).with("sudo systemctl stop test-dnsmasq.service")
    expect(vm_host.sshable).to receive(:cmd).with("sudo ip netns del test")
    expect(pr).to receive(:hop_rewrite_persisted)
    pr.start
  end

  it "rewrites persisted" do
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm).to receive(:update).with(ephemeral_net6: "2001::/64")
    expect(pr).to receive(:write_params_json)
    expect(vm_host.sshable).to receive(:cmd).with("sudo host/bin/setup-vm reassign-ip6 test", stdin: JSON.generate({storage: "storage_secrets"}))
    expect(pr).to receive(:hop_start_vm)
    pr.rewrite_persisted
  end

  it "starts vm" do
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm_host.sshable).to receive(:cmd).with("sudo ip -n test addr replace 1.0.0.1/8 dev ubid_to_tap_name")
    expect(vm_host.sshable).to receive(:cmd).with("sudo systemctl start test.service")
    expect(vm).to receive(:incr_update_firewall_rules)
    expect(pr).to receive(:pop).with("VM test updated")
    pr.start_vm
  end

  it "writes params json" do
    expect(pr).to receive(:vm_host).and_return(vm_host).at_least(:once)
    expect(vm).to receive(:params_json).with(nil).and_return("params_json")
    expect(vm_host.sshable).to receive(:cmd).with("sudo rm /vm/test/prep.json")
    expect(vm_host.sshable).to receive(:cmd).with("sudo -u test tee /vm/test/prep.json", stdin: "params_json")
    pr.write_params_json
  end
end
