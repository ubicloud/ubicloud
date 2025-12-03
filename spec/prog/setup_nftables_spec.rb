# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupNftables do
  subject(:sn) {
    described_class.new(Strand.new(prog: "SetupNftables"))
  }

  describe "#start" do
    it "Sets it up and pops" do
      sshable = create_mock_sshable(host: "1.1.1.1")
      vm_host = instance_double(VmHost, ubid: "vmhostubid", assigned_subnets: [
        instance_double(Address, cidr: instance_double(NetAddr::IPv4Net, version: 4, network: "1.1.1.1", to_s: "1.1.1.1")),
        instance_double(Address, cidr: instance_double(NetAddr::IPv4Net, version: 6, network: "::", to_s: "::")),
        instance_double(Address, cidr: instance_double(NetAddr::IPv4Net, version: 4, network: "123.123.123.0/24", to_s: "123.123.123.0/24"))
      ], sshable: sshable)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/setup-nftables.rb \\[\\\"123.123.123.0/24\\\"\\]")
      expect(sn).to receive(:sshable).and_return(sshable)
      expect(sn).to receive(:vm_host).and_return(vm_host).at_least(:once)

      expect { sn.start }.to exit({"msg" => "nftables was setup"})
    end
  end
end
