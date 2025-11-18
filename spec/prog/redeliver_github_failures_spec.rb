# frozen_string_literal: true

require_relative "../model/spec_helper"
require "octokit"

RSpec.describe Prog::RedeliverGithubFailures do
  subject(:rgf) {
    described_class.new(Strand.new(prog: "RedeliverGithubFailures", stack: [{"last_check_at" => "2023-10-19 22:27:47 +0000"}]))
  }

  describe "#wait" do
    it "redelivers failed deliveries and naps" do
      expect(Time).to receive(:now).and_return("2023-10-19 23:27:47 +0000").at_least(:once)
      expect(rgf).to receive(:redeliver_failed_deliveries).with(Time.utc(2023, 10, 19, 22, 27, 47))
      expect(rgf.strand).to receive(:save_changes)
      expect {
        expect { rgf.wait }.to nap(2 * 60)
      }.to change { rgf.strand.stack.first["last_check_at"] }.from("2023-10-19 22:27:47 +0000").to("2023-10-19 23:27:47 +0000")
    end
  end

  describe "failed deliveries" do
    let(:time) { Time.now }
    let(:app_client) { instance_double(Octokit::Client) }

    before do
      allow(Github).to receive(:app_client).and_return(app_client)
    end

    it "fetches failed deliveries" do
      expect(app_client).to receive(:get).with("/app/hook/deliveries?per_page=100").and_return([
        {guid: "1", status: "Fail", delivered_at: time + 5},
        {guid: "2", status: "Fail", delivered_at: time + 4},
        {guid: "3", status: "OK", delivered_at: time + 3}
      ])
      next_url = "/app/hook/deliveries?per_page=100&cursor=next_page"
      expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: instance_double(Sawyer::Relation, href: next_url)}))
      expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: nil}))
      expect(app_client).to receive(:get).with(next_url).and_return([
        {guid: "2", status: "OK", delivered_at: time + 2},
        {guid: "4", status: "Fail", delivered_at: time + 2},
        {guid: "4", status: "Fail", delivered_at: time + 1},
        {guid: "5", status: "Fail", delivered_at: time - 2},
        {guid: "6", status: "OK", delivered_at: time - 3}
      ])

      failed_deliveries = rgf.failed_deliveries(time)
      expect(failed_deliveries).to eq([
        {guid: "1", status: "Fail", delivered_at: time + 5},
        {guid: "4", status: "Fail", delivered_at: time + 2}
      ])
    end

    it "fetches failed deliveries with max page" do
      expect(app_client).to receive(:get).with("/app/hook/deliveries?per_page=100").and_return([
        {guid: "3", status: "Fail", delivered_at: time + 3}
      ])
      expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: instance_double(Sawyer::Relation, href: "next_url")}))
      expect(Clog).to receive(:emit).with("failed deliveries page limit reached").and_call_original
      expect(Clog).to receive(:emit).with("fetched deliveries").and_call_original
      failed_deliveries = rgf.failed_deliveries(time, 1)
      expect(failed_deliveries).to eq([{guid: "3", status: "Fail", delivered_at: time + 3}])
    end

    it "redelivers failed deliveries" do
      expect(rgf).to receive(:failed_deliveries).with(time).and_return([{id: "1"}, {id: "2"}])
      expect(app_client).to receive(:post).with("/app/hook/deliveries/1/attempts")
      expect(app_client).to receive(:post).with("/app/hook/deliveries/2/attempts")

      rgf.redeliver_failed_deliveries(time)
    end
  end
end
