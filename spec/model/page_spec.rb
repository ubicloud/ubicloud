# frozen_string_literal: true

require_relative "spec_helper"

require "json"

RSpec.describe Page do
  subject(:p) { described_class.create_with_id(tag: "dummy-tag") }

  describe "#trigger" do
    it "triggers a page in Pagerduty if key is present" do
      expect(Config).to receive(:pagerduty_key).and_return("dummy-key").at_least(:once)
      stub_request(:post, "https://events.pagerduty.com/v2/enqueue")
        .to_return(status: 200, body: {dedup_key: "dummy-dedup-key", message: "Event processed", status: "success"}.to_json, headers: {})

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
