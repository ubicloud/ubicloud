# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe IpsecTunnel do
  subject(:ipsec_tunnel) {
    described_class.new(
      src_nic_id: "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e",
      dst_nic_id: "46ca6ded-b056-4723-bd91-612959f52f6f"
    )
  }

  let(:vm_host) { instance_double(VmHost, sshable: instance_double(Sshable)) }
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

  describe "create_ipsec_tunnel" do
    it "creates an ipsec tunnel for vm" do
      expect(ipsec_tunnel).to receive(:src_nic).and_return(src_nic).at_least(:once)
      expect(ipsec_tunnel).to receive(:dst_nic).and_return(dst_nic).at_least(:once)
      expect(SecureRandom).to receive(:bytes).with(4).and_return("0xf34baf77")
      expect(SecureRandom).to receive(:bytes).with(4).and_return("0xdc6e4976")
      expect(vm_host.sshable).to receive(:cmd).with(
        "sudo bin/setup-ipsec vm12345 2a01:4f8:10a:128b:c0b5::/80 2a01:4f8:10a:128b:bdc9::/80 fd1b:9793:dcef:cd0a:264c::/79 fd1b:9793:dcef:cd0a:72b6::/79 10.9.39.31/32 10.9.39.9/32 out 0x30786633346261663737 0x30786463366534393736 12345678901234567890123456789012"
      ).and_return("ok")
      expect(vm_host.sshable).to receive(:cmd).with(
        "sudo bin/setup-ipsec vm67890 2a01:4f8:10a:128b:c0b5::/80 2a01:4f8:10a:128b:bdc9::/80 fd1b:9793:dcef:cd0a:264c::/79 fd1b:9793:dcef:cd0a:72b6::/79 10.9.39.31/32 10.9.39.9/32 fwd 0x30786633346261663737 0x30786463366534393736 12345678901234567890123456789012"
      ).and_return("ok")
      ipsec_tunnel.create_ipsec_tunnel
    end
  end

  describe "create private routes" do
    it "creates private routes for destination" do
      expect(ipsec_tunnel).to receive(:src_nic).and_return(src_nic).at_least(:once)
      expect(ipsec_tunnel).to receive(:dst_nic).and_return(dst_nic).at_least(:once)
      expect(vm_host.sshable).to receive(:cmd).with(
        "sudo ip -n vm12345 route replace fd1b:9793:dcef:cd0a:72b6::/79 dev vethivm12345"
      ).and_return("ok")
      expect(vm_host.sshable).to receive(:cmd).with(
        "sudo ip -n vm12345 route replace 10.9.39.9/32 dev vethivm12345"
      ).and_return("ok")

      ipsec_tunnel.create_private_routes
    end
  end

  describe "refresh" do
    it "refreshes the ipsec tunnel" do
      expect(ipsec_tunnel).to receive(:create_ipsec_tunnel).and_return(true)
      expect(ipsec_tunnel).to receive(:create_private_routes).and_return(true)
      ipsec_tunnel.refresh
    end
  end
end
