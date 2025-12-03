# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe IpsecTunnel do
  subject(:ipsec_tunnel) {
    described_class.new(
      src_nic_id: src_nic.id,
      dst_nic_id: dst_nic.id
    )
  }

  let(:vm_host) { instance_double(VmHost, sshable: Sshable.new) }
  let(:src_vm) {
    instance_double(
      Vm,
      ephemeral_net6: NetAddr.parse_net("2a01:4f8:10a:128b:c0b4::/79"),
      inhost_name: "vm12345",
      vm_host: vm_host
    )
  }
  let(:dst_vm) {
    instance_double(
      Vm,
      ephemeral_net6: NetAddr.parse_net("2a01:4f8:10a:128b:bdc8::/79"),
      inhost_name: "vm67890",
      vm_host: vm_host
    )
  }
  let(:src_nic) {
    instance_double(Nic,
      id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e",
      private_ipv6: "fd1b:9793:dcef:cd0a:264c::/79",
      private_ipv4: "10.9.39.31/32",
      vm: src_vm,
      encryption_key: "12345678901234567890123456789012")
  }
  let(:dst_nic) {
    instance_double(Nic,
      id: "46ca6ded-b056-4723-bd91-612959f52f6f",
      private_ipv6: "fd1b:9793:dcef:cd0a:72b6::/79",
      private_ipv4: "10.9.39.9/32",
      vm: dst_vm,
      encryption_key: "12345678901234567890123456789012")
  }

  it "returns vm_name properly" do
    expect(ipsec_tunnel.vm_name(src_nic)).to eq("vm12345")
    expect(ipsec_tunnel.vm_name(dst_nic)).to eq("vm67890")
  end
end
