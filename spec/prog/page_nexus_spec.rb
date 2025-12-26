# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PageNexus do
  subject(:pn) {
    described_class.new(Strand.new).tap {
      it.instance_variable_set(:@page, pg)
    }
  }

  let(:pg) { Page.new }

  describe "#start" do
    it "triggers page and hops" do
      expect(pg).to receive(:trigger)
      expect { pn.start }.to hop("wait")
    end
  end

  describe "#wait" do
    it "exits when resolved" do
      expect(pn).to receive(:when_resolve_set?).and_yield
      expect(pg).to receive(:resolve)
      expect(pg).to receive(:destroy)
      expect { pn.wait }.to exit({"msg" => "page is resolved"})
    end

    it "naps" do
      expect { pn.wait }.to nap(6 * 60 * 60)
    end
  end

  describe ".assemble" do
    let(:summary) { "Test Summary" }
    let(:tag_parts) { ["TestTag", "resource123"] }
    let(:related_resources) { ["ubid1", "ubid2"] }
    let(:severity) { "warning" }
    let(:extra_data) { {"foo" => "bar"} }

    it "creates a new page when one does not exist" do
      expect {
        described_class.assemble(summary, tag_parts, related_resources, severity: severity, extra_data: extra_data)
      }.to change(Page, :count).by(1).and change(Strand, :count).by(1)

      page = Page.last
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
      existing_page = Page.create(
        summary: "Old Summary",
        tag: "TestTag-resource123",
        severity: "error",
        details: {"old_data" => "old_value", "related_resources" => ["old_ubid"]}
      )

      expect {
        described_class.assemble(summary, tag_parts, related_resources, severity: severity, extra_data: extra_data)
      }.not_to change(Page, :count)

      existing_page.reload
      expect(existing_page.summary).to eq(summary)
      expect(existing_page.severity).to eq(severity)
      expect(existing_page.details["related_resources"]).to eq(related_resources)
      expect(existing_page.details["foo"]).to eq("bar")
      expect(existing_page.details["old_data"]).to be_nil
    end
  end
end
