# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupNdpProxy do
  subject(:snp) {
    described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}], prog: "SetupNdpProxy"))
  }

  let(:vmh) { Prog::Vm::HostNexus.assemble("1.1.1.1", net6: "2a01:4f8:10a:128b::/64", ndp_needed: true).subject }

  describe "#start" do
    it "installs the ndp proxy and pops" do
      expect(snp.sshable).to receive(:_cmd).with("sudo host/bin/setup-ndp-proxy install 2a01:4f8:10a:128b::/64")

      expect { snp.start }.to exit({"msg" => "ndp proxy was setup"})
    end

    it "pops without installing when the host does not need ndp" do
      vmh.update(ndp_needed: false)
      expect(snp.sshable).not_to receive(:_cmd)

      expect { snp.start }.to exit({"msg" => "ndp proxy not needed"})
    end

    it "waits for LearnNetwork when the host has no net6 yet, under a deadline" do
      vmh.update(net6: nil)
      expect(snp.sshable).not_to receive(:_cmd)

      expect { snp.start }.to nap(5)
      expect(snp.deadline_at).not_to be_nil
    end
  end
end
