# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::Heartbeat do
  subject(:hb) {
    described_class.new(Strand.new(prog: "Heartbeat"))
  }

  describe "#wait" do
    before { allow(Config).to receive(:heartbeat_url).and_return("http://localhost:3000") }

    it "fails if it can't connect to the database" do
      expect(DB).to receive(:[]).with("SELECT 1").and_raise(Sequel::DatabaseConnectionError)

      expect { hb.wait }.to raise_error Sequel::DatabaseConnectionError
    end

    it "naps if it can't send request in expected time" do
      stub_request(:get, "http://localhost:3000").and_raise(Excon::Error::Timeout)
      expect(Clog).to receive(:emit).with("heartbeat request timed out")
      expect { hb.wait }.to nap(10)
    end

    it "pushes a heartbeat and naps" do
      stub_request(:get, "http://localhost:3000").to_return(status: 200)

      expect { hb.wait }.to nap(10)
    end
  end
end
