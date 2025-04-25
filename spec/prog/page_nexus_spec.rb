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
end
