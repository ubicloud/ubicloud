# frozen_string_literal: true

RSpec.describe EcbExchangeRate do
  describe ".usd_to_eur" do
    it "returns the inverted latest ECB USD rate" do
      body = {dataSets: [{series: {"0:0:0:0:0" => {observations: {"0" => [1.1179, 0, 0, nil, nil]}}}}]}.to_json
      stub_request(:get, described_class::URL).to_return(status: 200, body:)
      expect(described_class.usd_to_eur).to eq 0.894534
    end

    it "returns nil when the ECB API fails" do
      stub_request(:get, described_class::URL).to_return(status: 503)
      expect(Clog).to receive(:emit).with("Could not fetch ECB exchange rate", instance_of(Hash)).and_call_original
      expect(described_class.usd_to_eur).to be_nil
    end
  end
end
