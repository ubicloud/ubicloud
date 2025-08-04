# frozen_string_literal: true

require_relative "spec_helper"

require "json"

RSpec.describe Page do
  subject(:p) { described_class.create(tag: "dummy-tag") }

  describe "#trigger" do
    before do
      expect(Config).to receive(:pagerduty_key).and_return("dummy-key").at_least(:once)
      stub_request(:post, "https://events.pagerduty.com/v2/enqueue")
        .to_return(status: 200, body: {dedup_key: "dummy-dedup-key", message: "Event processed", status: "success"}.to_json, headers: {})
    end

    it "triggers a page in Pagerduty if key is present" do
      expect(p).to receive(:details).and_return({}).at_least(:once)
      p.trigger
    end

    it "triggers a page with custom_details" do
      expect(p).to receive(:details).and_return({"related_resources" => ["a410a91a-dc31-4119-9094-3c6a1fb49601"]}).at_least(:once)
      p.trigger
    end

    it "triggers a page with custom_details and log link" do
      expect(Config).to receive(:pagerduty_log_link).and_return("https://logviewer.com?q=<ubid>").at_least(:once)
      expect(p).to receive(:details).and_return({"related_resources" => ["a410a91a-dc31-4119-9094-3c6a1fb49601"]}).at_least(:once)
      p.trigger
    end
  end

  describe "#resolve" do
    it "resolves the page in Pagerduty if key is present" do
      expect(Config).to receive(:pagerduty_key).and_return("dummy-key").at_least(:once)
      stub_request(:post, "https://events.pagerduty.com/v2/enqueue")
        .to_return(status: 200, body: {dedup_key: "dummy-dedup-key", message: "Event processed", status: "success"}.to_json, headers: {})

      p.resolve
    end
  end
end
