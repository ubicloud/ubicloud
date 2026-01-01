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
end
