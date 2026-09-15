# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupNdpProxy do
  subject(:snp) {
    described_class.new(Strand.new(parent_id:, stack: [{"subject_id" => vmh.id}], prog: "SetupNdpProxy"))
  }

  let(:vmh) { Prog::Vm::HostNexus.assemble("1.1.1.1", net6: "2a01:4f8:10a:128b::/64", ndp_needed: true).subject }
  let(:parent_id) { nil }
  let(:page_tag_parts) { ["NdpProxyNoNet6", vmh.ubid] }

  describe "#start" do
    it "installs the ndp proxy under a deadline and pops" do
      expect(snp.sshable).to receive(:_cmd).with("sudo host/bin/setup-ndp-proxy install 2a01:4f8:10a:128b::/64")

      expect { snp.start }.to exit({"msg" => "ndp proxy was setup"})
      expect(snp.deadline_at).not_to be_nil
    end

    it "resolves the no-net6 page once the install succeeds" do
      page = Prog::PageNexus.assemble("no net6", page_tag_parts, vmh.ubid, resource_id: vmh.id).subject
      expect(snp.sshable).to receive(:_cmd).with("sudo host/bin/setup-ndp-proxy install 2a01:4f8:10a:128b::/64")

      expect { snp.start }.to exit({"msg" => "ndp proxy was setup"})
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
    end

    it "pops without installing when the host does not need ndp" do
      vmh.update(ndp_needed: false)
      expect(snp.sshable).not_to receive(:_cmd)

      expect { snp.start }.to exit({"msg" => "ndp proxy not needed"})
    end

    context "when the host has no net6 yet" do
      # The host's own strand shares its id, and prep buds this prog under it.
      let(:parent_id) { vmh.id }

      before { vmh.update(net6: nil) }

      it "waits while the LearnNetwork sibling can still fill it in" do
        Strand.create(parent_id:, prog: "LearnNetwork", label: "start", stack: [{"subject_id" => vmh.id}])
        expect(snp.sshable).not_to receive(:_cmd)

        expect { snp.start }.to nap(5)
        expect(snp.deadline_at).not_to be_nil
        expect(Page.from_tag_parts(*page_tag_parts)).to be_nil
      end

      it "pages and pops once LearnNetwork finished without one" do
        Strand.create(parent_id:, prog: "LearnNetwork", label: "start", stack: [{"subject_id" => vmh.id}], exitval: {"msg" => "learned network information"})
        expect(snp.sshable).not_to receive(:_cmd)

        expect { snp.start }.to exit({"msg" => "ndp proxy skipped: no net6"})
        page = Page.from_tag_parts(*page_tag_parts)
        expect(page.summary).to eq("#{vmh.ubid} needs the NDP proxy but has no net6")
        expect(page.resource_id).to eq(vmh.id)
      end
    end

    it "pages and pops at once on a detached rollout without net6" do
      vmh.update(net6: nil)
      expect(snp.sshable).not_to receive(:_cmd)

      expect { snp.start }.to exit({"msg" => "ndp proxy skipped: no net6"})
      expect(Page.from_tag_parts(*page_tag_parts)).not_to be_nil
    end
  end
end
