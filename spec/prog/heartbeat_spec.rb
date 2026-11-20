# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::Heartbeat do
  subject(:hb) {
    described_class.new(Strand.new(prog: "Heartbeat"))
  }

  describe "#wait" do
    before { allow(Config).to receive(:heartbeat_url).and_return("http://localhost:3000") }

    it "naps if it can't send request in expected time" do
      expect(hb).to receive(:fetch_connected).and_return(described_class::EXPECTED)
      stub_request(:get, "http://localhost:3000").and_raise(Excon::Error::Timeout)
      expect(Clog).to receive(:emit).with("heartbeat request timed out", instance_of(Hash)).and_call_original
      expect { hb.wait }.to nap(10)
    end

    it "naps if not all expected application types are connected" do
      expect(Clog).to receive(:emit).with("some expected connected clover services are missing", {heartbeat_missing: {difference: ["monitor", "respirate"]}})

      req = stub_request(:get, "http://localhost:3000").to_return(status: 200)
      expect { hb.wait }.to nap(10)
      expect(req).not_to have_been_requested
    end

    it "pushes a heartbeat and naps" do
      req = stub_request(:get, "http://localhost:3000").to_return(status: 200)
      expect(hb).to receive(:fetch_connected).and_return(described_class::EXPECTED)

      expect { hb.wait }.to nap(10)
      expect(req).to have_been_requested
    end
  end
end
