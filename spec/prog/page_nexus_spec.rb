# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PageNexus do
  subject(:pn) { described_class.new(Strand[pg.id]) }

  let!(:pg) {
    pg = Page.create(tag: "test-page-tag", summary: "Test summary", details: {})
    Strand.create_with_id(pg, prog: "PageNexus", label: "start")
    pg
  }

  describe "#start" do
    it "triggers page and hops" do
      expect { pn.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "exits when resolved" do
      pn.incr_resolve
      expect { pn.wait }.to exit({"msg" => "page is resolved"})
      expect(pg.exists?).to be false
    end

    it "naps" do
      expect { pn.wait }.to nap(6 * 60 * 60)
    end
  end

  describe ".assemble" do
    let(:summary) { "New Page Summary" }
    let(:tag_parts) { ["TestTag", "resource123"] }
    let(:related_resources) { ["ubid1", "ubid2"] }
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

    it "updates existing page when one exists with same tag" do
      existing_page = described_class.assemble(
        "Old Summary",
        tag_parts,
        ["old_ubid"],
        severity: "error",
        extra_data: {"old_data" => "old_value"}
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
  end
end
