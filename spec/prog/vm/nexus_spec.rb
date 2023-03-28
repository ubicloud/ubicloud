# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::Vm::Nexus do
  it "creates the user and key record" do
    private_subnets = [
      NetAddr::IPv6Net.parse("fd55:666:cd1a:ffff::/64"),
      NetAddr::IPv6Net.parse("fd12:345:6789:0abc::/64")
    ]
    st = described_class.assemble("some_ssh_key", private_subnets: private_subnets)
    vm = Vm[st.id]
    vm.update(ephemeral_net6: "fe80::/64")

    expect(vm.unix_user).to eq("ubi")
    expect(vm.public_key).to eq("some_ssh_key")

    prog = described_class.new(st)
    sshable = instance_spy(Sshable)
    vmh = instance_double(VmHost, sshable: sshable)

    expect(st).to receive(:load).and_return(prog)
    expect(prog).to receive(:host).and_return(vmh).at_least(:once)

    expect(sshable).to receive(:cmd).with(/echo (.|\n)* \| sudo -u vm[0-9a-z]+ tee/) do
      require "json"
      params = JSON(_1.shellsplit[1])
      expect(params["unix_user"]).to eq("ubi")
      expect(params["ssh_public_key"]).to eq("some_ssh_key")
      expect(params["public_ipv6"]).to eq("fe80::/64")
      expect(params["private_subnets"]).to include(*private_subnets.map { |s| s.to_s })
      expect(params["boot_image"]).to eq("ubuntu-jammy")
    end

    st.update(label: "prep")
    st.run
  end
end
