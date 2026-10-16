# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupCsumGuard do
  subject(:scg) {
    described_class.new(Strand.new(stack: [{"subject_id" => vmh.id, "enable" => enable}], prog: "SetupCsumGuard"))
  }

  let(:vmh) { Prog::Vm::HostNexus.assemble("1.1.1.1").subject }
  let(:page_tag_parts) { ["CsumGuardFailed", vmh.ubid] }

  def ssh_error(stderr)
    Sshable::SshError.new("setup-csum-guard", "", stderr, 1, nil)
  end

  describe "#start" do
    context "when enabling" do
      let(:enable) { true }

      it "installs the guard under a deadline, then records it" do
        expect(scg.sshable).to receive(:_cmd).with("sudo host/bin/setup-csum-guard install") do
          expect(vmh.reload.csum_guard_enabled).to be false
        end

        expect { scg.start }.to exit({"msg" => "csum guard installed"})
        expect(scg.deadline_at).not_to be_nil
        expect(vmh.reload.csum_guard_enabled).to be true
      end

      it "pages and returns without recording it when the install fails" do
        expect(scg.sshable).to receive(:_cmd).with("sudo host/bin/setup-csum-guard install")
          .and_raise(ssh_error("Kernel 5.15.0 is older than 6.3"))

        expect { scg.start }.to exit({"msg" => "csum guard install failed"})
        expect(vmh.reload.csum_guard_enabled).to be false
        page = Page.from_tag_parts(*page_tag_parts)
        expect(page.summary).to eq("#{vmh.ubid} could not install the checksum guard")
        expect(page.details["stderr"]).to eq("Kernel 5.15.0 is older than 6.3")
      end

      it "keeps only the end of a long error in the page" do
        expect(scg.sshable).to receive(:_cmd).and_raise(ssh_error("x" * 1000 + "y" * 2000))

        expect { scg.start }.to exit({"msg" => "csum guard install failed"})
        expect(Page.from_tag_parts(*page_tag_parts).details["stderr"]).to eq("y" * 2000)
      end

      it "resolves an earlier failure page once the install succeeds" do
        page = Prog::PageNexus.assemble("failed", page_tag_parts, vmh.ubid, resource_id: vmh.id).subject
        expect(scg.sshable).to receive(:_cmd).with("sudo host/bin/setup-csum-guard install")

        expect { scg.start }.to exit({"msg" => "csum guard installed"})
        expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
      end
    end

    context "when disabling" do
      let(:enable) { false }

      it "uninstalls the guard, then records it" do
        vmh.update(csum_guard_enabled: true)
        expect(scg.sshable).to receive(:_cmd).with("sudo host/bin/setup-csum-guard uninstall")

        expect { scg.start }.to exit({"msg" => "csum guard uninstalled"})
        expect(vmh.reload.csum_guard_enabled).to be false
      end

      it "pages and leaves the record when the uninstall fails" do
        vmh.update(csum_guard_enabled: true)
        expect(scg.sshable).to receive(:_cmd).and_raise(ssh_error("tc failed"))

        expect { scg.start }.to exit({"msg" => "csum guard uninstall failed"})
        expect(vmh.reload.csum_guard_enabled).to be true
        expect(Page.from_tag_parts(*page_tag_parts).summary).to eq("#{vmh.ubid} could not uninstall the checksum guard")
      end
    end
  end
end
