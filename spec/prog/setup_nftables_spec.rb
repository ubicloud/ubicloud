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
  end
end
