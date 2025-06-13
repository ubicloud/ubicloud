# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::PopulateIpv4Cache do
  subject(:pc) {
    described_class.new(Strand.new(prog: "PopulateIpv4Cache"))
  }

  describe "#wait" do
    it "populates file and naps an hour" do
      expect(Util).to receive(:populate_ipv4_txt).and_call_original
      expect { pc.wait }.to nap(60 * 60)
    end
  end
end
