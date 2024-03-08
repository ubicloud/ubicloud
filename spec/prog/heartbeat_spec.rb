# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::Heartbeat do
  subject(:hb) {
    described_class.new(Strand.new(prog: "Heartbeat"))
  }

  describe "#wait" do
    before { allow(Config).to receive(:heartbeat_url).and_return("http://localhost:3000") }

    it "fails if it can't connect to the database" do
      expect(DB).to receive(:get).with(described_class::CONNECTED_APPLICATION_QUERY).and_raise(Sequel::DatabaseConnectionError)

      expect { hb.wait }.to raise_error Sequel::DatabaseConnectionError
    end

    it "naps if it can't send request in expected time" do
      expect(DB).to receive(:get).with(described_class::CONNECTED_APPLICATION_QUERY).and_return(3)
      stub_request(:get, "http://localhost:3000").and_raise(Excon::Error::Timeout)
      expect(Clog).to receive(:emit).with("heartbeat request timed out")
      expect { hb.wait }.to nap(10)
    end

    it "naps if not all expected application types are connected" do
      expect(DB).to receive(:get).with(described_class::CONNECTED_APPLICATION_QUERY).and_return(2)
      req = stub_request(:get, "http://localhost:3000").to_return(status: 200)
      expect { hb.wait }.to nap(10)
      expect(req).not_to have_been_requested
    end

    it "pushes a heartbeat and naps" do
      req = stub_request(:get, "http://localhost:3000").to_return(status: 200)
      expect(DB).to receive(:get).with(described_class::CONNECTED_APPLICATION_QUERY).and_return(3)

      expect { hb.wait }.to nap(10)
      expect(req).to have_been_requested
    end
  end
end
