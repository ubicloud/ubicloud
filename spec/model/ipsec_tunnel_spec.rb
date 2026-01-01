# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe IpsecTunnel do
  subject(:ipsec_tunnel) {
    described_class.create(src_nic_id: src_nic.id, dst_nic_id: dst_nic.id)
  }

  let(:ps) {
    PrivateSubnet.create(
      name: "test-ps",
      location_id: Location::HETZNER_FSN1_ID,
      net6: "fd10:9b0b:6b4b:8fbb::/64",
      net4: "10.0.0.0/26",
      state: "waiting",
      project_id: Project.create(name: "test-project").id
    )
  }
  let(:vm_host) { create_vm_host }
  let(:src_vm) { create_vm(name: "src-vm", vm_host_id: vm_host.id) }
  let(:dst_vm) { create_vm(name: "dst-vm", vm_host_id: vm_host.id) }
  let(:src_nic) {
    Nic.create(
      private_subnet_id: ps.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:abc::",
      private_ipv4: "10.0.0.1",
      mac: "00:00:00:00:00:01",
      name: "src-nic",
      vm_id: src_vm.id,
      state: "active"
    )
  }
  let(:dst_nic) {
    Nic.create(
      private_subnet_id: ps.id,
      private_ipv6: "fd10:9b0b:6b4b:8fbb:def::",
      private_ipv4: "10.0.0.2",
      mac: "00:00:00:00:00:02",
      name: "dst-nic",
      vm_id: dst_vm.id,
      state: "active"
    )
  }

  it "returns vm_name properly" do
    expect(ipsec_tunnel.vm_name(src_nic)).to eq(src_vm.inhost_name)
    expect(ipsec_tunnel.vm_name(dst_nic)).to eq(dst_vm.inhost_name)
  end
end
