# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupNftables do
  subject(:sn) {
    described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}], prog: "SetupNftables"))
  }

  let(:vmh) { Prog::Vm::HostNexus.assemble("1.1.1.1").subject }

  describe "#start" do
    it "Sets it up and pops" do
      Address.create(cidr: "2001:db8::/64", routed_to_host_id: vmh.id)
      Address.create(cidr: "123.123.123.0/24", routed_to_host_id: vmh.id)

      expect(sn.sshable).to receive(:_cmd).with("sudo host/bin/setup-nftables.rb \\[\\\"123.123.123.0/24\\\"\\]")

      expect { sn.start }.to exit({"msg" => "nftables was setup"})
    end

    # A Leaseweb switched segment member is claimed by the host itself and no
    # VM can take it, so nothing would ever add it to the allowed set and a
    # block would strand it. The claim is its assigned_host_address row.
    it "never blocks an address the host claims" do
      claimed = Address.create(cidr: "23.105.176.1/32", routed_to_host_id: vmh.id)
      AssignedHostAddress.create(host_id: vmh.id, ip: "23.105.176.1", address_id: claimed.id)
      Address.create(cidr: "123.123.123.0/24", routed_to_host_id: vmh.id)

      expect(sn.sshable).to receive(:_cmd).with("sudo host/bin/setup-nftables.rb \\[\\\"123.123.123.0/24\\\"\\]")

      expect { sn.start }.to exit({"msg" => "nftables was setup"})
    end
  end
end
