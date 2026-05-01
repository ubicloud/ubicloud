# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PageNexus do
  subject(:pn) do
    pg = Page.create(tag: "test-page-tag", summary: "Test summary", details: {})
    st = Strand.create_with_id(pg, prog: "PageNexus", label: "start")
    described_class.new(st)
  end

  let(:pg) { pn.page }

  describe "#start" do
    it "triggers page and hops" do
      expect(pg).to receive(:trigger).and_call_original
      expect { pn.start }.to hop("wait")
    end

    it "does not trigger if triggers are supressed" do
      refresh_frame(pn, new_values: {"suppress_triggers" => true})
      expect(pg).not_to receive(:trigger)
      expect { pn.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "resolves and exits when resolved" do
      pn.incr_resolve
      expect(pg).to receive(:resolve).and_call_original
      expect { pn.wait }.to exit({"msg" => "page is resolved"})
      expect(pg.exists?).to be false
    end

    it "skips resolving and exits when resolved when triggers are suppressed" do
      pn.incr_resolve
      refresh_frame(pn, new_values: {"suppress_triggers" => true})
      expect(pg).not_to receive(:resolve)
      expect { pn.wait }.to exit({"msg" => "page is resolved"})
      expect(pg.exists?).to be false
    end

    it "triggers page when retrigger semaphore is set" do
      expect(pg).to receive(:trigger)
      pn.incr_retrigger
      expect { pn.wait }.to nap(6 * 60 * 60)
      expect(pg.semaphores.map(&:name)).not_to include("retrigger")
    end

    it "triggers page when retrigger semaphore is set even when triggers are suppressed" do
      refresh_frame(pn, new_values: {"suppress_triggers" => true})
      expect(pg).to receive(:trigger)
      pn.incr_retrigger
      expect { pn.wait }.to nap(6 * 60 * 60)
      expect(pg.semaphores.map(&:name)).not_to include("retrigger")
      expect(pn.strand.stack[0]["suppress_triggers"]).to be false
    end

    it "naps" do
      expect { pn.wait }.to nap(6 * 60 * 60)
    end
  end

  describe ".assemble" do
    let(:summary) { "New Page Summary" }
    let(:tag_parts) { ["TestTag", "resource123"] }
    let(:related_resources) { [Vm.generate_ubid.to_s, VmHost.generate_ubid.to_s] }
    let(:severity) { "warning" }
    let(:extra_data) { {"foo" => "bar"} }

    it "creates a new page when one does not exist" do
      expect {
        described_class.assemble(summary, tag_parts, related_resources, severity:, extra_data:)
      }.to change(Page, :count).by(1).and change(Strand, :count).by(1)

      page = Page.from_tag_parts(tag_parts)
      expect(page.summary).to eq(summary)
      expect(page.tag).to eq("TestTag-resource123")
      expect(page.severity).to eq(severity)
      expect(page.details["related_resources"]).to eq(related_resources)
      expect(page.details["foo"]).to eq("bar")
      expect(page.resolved_at).to be_nil

      strand = Strand.last
      expect(strand.prog).to eq("PageNexus")
      expect(strand.label).to eq("start")
    end

    it "suppresses triggers for page that may duplicate recent page" do
      vmh = create_vm_host
      expect {
        described_class.assemble(summary, tag_parts + [vmh.ubid], vmh.ubid, severity:, extra_data:)
      }.to change(Page, :count).from(0).to(1)
        .and change(Strand, :count).from(0).to(1)
        .and change(DB[:page_root_resource], :count).from(0).to(1)
        .and change(DB[:page_root_resource].exclude(:duplicate), :count).from(0).to(1)
      st = Strand.first
      expect(st.stack[0]["suppress_triggers"]).to be_nil

      vmhs = create_vm_host_slice(vm_host_id: vmh.id)

      expect {
        described_class.assemble(summary, tag_parts, vmhs.ubid, severity:, extra_data:)
      }.to change(Page, :count).from(1).to(2)
        .and change(Strand, :count).from(1).to(2)
        .and change(DB[:page_root_resource], :count).from(1).to(2)
        .and not_change(DB[:page_root_resource].exclude(:duplicate), :count)

      expect(Strand.exclude(id: st.id).first.stack[0]["suppress_triggers"]).to be true
    end

    it "does not suppress triggers for page that may duplicate older page" do
      vmh = create_vm_host
      expect {
        described_class.assemble(summary, tag_parts + [vmh.ubid], vmh.ubid, severity:, extra_data:)
      }.to change(Page, :count).from(0).to(1)
        .and change(Strand, :count).from(0).to(1)
        .and change(DB[:page_root_resource], :count).from(0).to(1)
        .and change(DB[:page_root_resource].exclude(:duplicate), :count).from(0).to(1)
      st = Strand.first
      expect(st.stack[0]["suppress_triggers"]).to be_nil

      vmhs = create_vm_host_slice(vm_host_id: vmh.id)
      DB[:page_root_resource].update(at: Time.now - 60 * 60)

      expect {
        described_class.assemble(summary, tag_parts, vmhs.ubid, severity:, extra_data:)
      }.to change(Page, :count).from(1).to(2)
        .and change(Strand, :count).from(1).to(2)
        .and change(DB[:page_root_resource], :count).from(1).to(2)
        .and change(DB[:page_root_resource].exclude(:duplicate), :count).from(1).to(2)

      expect(Strand.exclude(id: st.id).first.stack[0]["suppress_triggers"]).to be_nil
    end

    it "does not suppress triggers for page when a duplicate page exists that suppressed pages" do
      vmh = create_vm_host
      expect {
        described_class.assemble(summary, tag_parts + [vmh.ubid], vmh.ubid, severity:, extra_data:)
      }.to change(Page, :count).from(0).to(1)
        .and change(Strand, :count).from(0).to(1)
        .and change(DB[:page_root_resource], :count).from(0).to(1)
        .and change(DB[:page_root_resource].exclude(:duplicate), :count).from(0).to(1)
      st = Strand.first
      expect(st.stack[0]["suppress_triggers"]).to be_nil

      gi = GithubInstallation.create(installation_id: 1, name: "foo", type: "bar")
      vmhs = create_vm_host_slice(vm_host_id: vmh.id)

      expect {
        described_class.assemble(summary, tag_parts, [vmhs.ubid, gi.ubid], severity:, extra_data:)
      }.to change(Page, :count).from(1).to(2)
        .and change(Strand, :count).from(1).to(2)
        .and change(DB[:page_root_resource], :count).from(1).to(3)
        .and not_change(DB[:page_root_resource].exclude(:duplicate), :count)

      st2 = Strand.exclude(id: st.id).first
      expect(st2.stack[0]["suppress_triggers"]).to be true

      expect {
        described_class.assemble(summary, tag_parts + [gi.ubid], gi.ubid, severity:, extra_data:)
      }.to change(Page, :count).from(2).to(3)
        .and change(Strand, :count).from(2).to(3)
        .and change(DB[:page_root_resource], :count).from(3).to(4)
        .and change(DB[:page_root_resource].exclude(:duplicate), :count).from(1).to(2)

      expect(Strand.exclude(id: [st.id, st2.id]).first.stack[0]["suppress_triggers"]).to be_nil
    end

    it "updates existing page when one exists with same tag" do
      existing_page = described_class.assemble(
        "Old Summary",
        tag_parts,
        [Vm.generate_ubid.to_s],
        severity: "error",
        extra_data: {"old_data" => "old_value"},
      ).subject

      expect(existing_page.summary).not_to eq(summary)
      expect(existing_page.severity).not_to eq(severity)
      expect(existing_page.details["related_resources"]).not_to eq(related_resources)
      expect(existing_page.details["old_data"]).to eq("old_value")
      expect(existing_page.details["foo"]).to be_nil

      expect {
        described_class.assemble(summary, tag_parts, related_resources, severity:, extra_data:)
      }.to not_change(Page, :count).and not_change(Strand, :count)

      existing_page.reload
      expect(existing_page.summary).to eq(summary)
      expect(existing_page.severity).to eq(severity)
      expect(existing_page.details["related_resources"]).to eq(related_resources)
      expect(existing_page.details["foo"]).to eq("bar")
      expect(existing_page.details["old_data"]).to be_nil
    end

    it "sets retrigger semaphore when severity is increased" do
      existing_page = described_class.assemble(
        "Old Summary",
        tag_parts,
        [Vm.generate_ubid.to_s],
        severity: "warning",
      ).subject

      expect(existing_page.semaphores.map(&:name)).not_to include("retrigger")

      described_class.assemble(summary, tag_parts, related_resources, severity: "error")

      existing_page.reload
      expect(existing_page.semaphores.map(&:name)).to include("retrigger")
    end

    it "does not set retrigger semaphore when severity is decreased" do
      existing_page = described_class.assemble(
        "Old Summary",
        tag_parts,
        [Vm.generate_ubid.to_s],
        severity: "error",
      ).subject

      described_class.assemble(summary, tag_parts, related_resources, severity: "warning")

      expect(existing_page.semaphores.map(&:name)).not_to include("retrigger")
    end

    it "does not set retrigger semaphore when severity is unchanged" do
      existing_page = described_class.assemble(
        "Old Summary",
        tag_parts,
        [Vm.generate_ubid.to_s],
        severity: "error",
      ).subject

      described_class.assemble(summary, tag_parts, related_resources, severity: "error")

      expect(existing_page.semaphores.map(&:name)).not_to include("retrigger")
    end
  end
end
