# frozen_string_literal: true

require "spec_helper"

RSpec.describe VictoriaMetrics::TeeClient do
  subject(:tee_client) { described_class.new(primary:, secondaries:) }

  let(:primary) { instance_double(VictoriaMetrics::Client) }
  let(:secondary) { instance_double(VictoriaMetrics::Client) }
  let(:secondaries) { [secondary] }
  let(:scrape) { VictoriaMetrics::Client::Scrape.new(time: Time.now, samples: "metric 1") }

  it "delegates read methods to the primary client only" do
    expect(primary).to receive(:query).with(query: "up").and_return("query result")
    expect(secondary).not_to receive(:query)
    expect(tee_client.query(query: "up")).to eq("query result")
  end

  describe "#import_prometheus" do
    it "forwards to all secondaries and returns the primary's result" do
      expect(primary).to receive(:import_prometheus).with(scrape, {label: "value"}).and_return("primary result")
      expect(secondary).to receive(:import_prometheus).with(scrape, {label: "value"})
      expect(tee_client.import_prometheus(scrape, {label: "value"})).to eq("primary result")
    end

    it "raises if the primary write fails, without attempting the secondaries" do
      expect(primary).to receive(:import_prometheus).and_raise(VictoriaMetrics::ClientError.new("boom"))
      expect(secondary).not_to receive(:import_prometheus)
      expect { tee_client.import_prometheus(scrape) }.to raise_error(VictoriaMetrics::ClientError, "boom")
    end

    it "logs and swallows secondary write failures" do
      expect(primary).to receive(:import_prometheus).and_return("primary result")
      expect(secondary).to receive(:import_prometheus).and_raise(VictoriaMetrics::ClientError.new("boom"))
      expect(Clog).to receive(:emit).with("VictoriaMetrics secondary write failed", instance_of(Hash)).and_call_original
      expect(tee_client.import_prometheus(scrape)).to eq("primary result")
    end

    it "still writes to remaining secondaries when one fails" do
      other_secondary = instance_double(VictoriaMetrics::Client)
      tee_client = described_class.new(primary:, secondaries: [secondary, other_secondary])
      expect(primary).to receive(:import_prometheus).and_return("primary result")
      expect(secondary).to receive(:import_prometheus).and_raise(VictoriaMetrics::ClientError.new("boom"))
      expect(other_secondary).to receive(:import_prometheus)
      expect(Clog).to receive(:emit).and_call_original
      expect(tee_client.import_prometheus(scrape)).to eq("primary result")
    end
  end
end
