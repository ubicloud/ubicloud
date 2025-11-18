# frozen_string_literal: true

require_relative "../model/spec_helper"
require "octokit"

RSpec.describe Prog::RedeliverGithubFailures do
  subject(:prog) {
    described_class.new(Strand.create(prog: "RedeliverGithubFailures", label: "wait", stack: [{"last_check_at" => "2023-10-19 22:27:47 +0000"}]))
  }

  let(:time) { Time.utc(2023, 10, 19, 22, 27, 47) }
  let(:app_client) { instance_double(Octokit::Client) }

  before do
    allow(Github).to receive(:app_client).and_return(app_client)
  end

  describe "#wait" do
    it "redelivers failed deliveries and naps" do
      expect(Time).to receive(:now).and_return("2023-10-19 23:27:47 +0000").at_least(:once)
      expect(prog).to receive(:failed_deliveries).with(time).and_return([{guid: "1", id: "11", status: "Fail", delivered_at: time + 5}])
      expect(Clog).to receive(:emit).with("redelivered failed deliveries").and_wrap_original do |&blk|
        expect(blk.call).to eq(deliveries: {failed: 1})
      end
      expect(Clog).to receive(:emit).with("redelivering failed delivery").and_wrap_original do |&blk|
        expect(blk.call).to eq(delivery: {delivered_at: time + 5, guid: "1", id: "11", status: "Fail"})
      end
      expect(app_client).to receive(:post).with("/app/hook/deliveries/11/attempts")
      expect { prog.wait }.to nap(2 * 60)
        .and change { prog.strand.stack.first["last_check_at"] }.from("2023-10-19 22:27:47 +0000").to("2023-10-19 23:27:47 +0000")
    end
  end

  describe "failed deliveries" do
    it "fetches failed deliveries" do
      # page 1
      expect(app_client).to receive(:get).with("/app/hook/deliveries?per_page=100").and_return([
        {guid: "1", id: "11", status: "Fail", delivered_at: time + 5},
        {guid: "2", id: "21", status: "Fail", delivered_at: time + 4},
        {guid: "3", id: "31", status: "OK", delivered_at: time + 3}
      ])
      # page 2
      next_url = "/app/hook/deliveries?per_page=100&cursor=next_page"
      expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: instance_double(Sawyer::Relation, href: next_url)}))
      expect(app_client).to receive(:get).with(next_url).and_return([
        {guid: "2", id: "21", status: "OK", delivered_at: time + 2},
        {guid: "4", id: "41", status: "Fail", delivered_at: time + 2},
        {guid: "4", id: "42", status: "Fail", delivered_at: time + 1},
        {guid: "5", id: "51", status: "Fail", delivered_at: time - 2},
        {guid: "6", id: "61", status: "OK", delivered_at: time - 3}
      ])
      # page 3
      expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: nil}))

      expect(prog.failed_deliveries(time)).to eq([
        {guid: "1", id: "11", status: "Fail", delivered_at: time + 5},
        {guid: "4", id: "41", status: "Fail", delivered_at: time + 2}
      ])
    end

    it "fetches failed deliveries with max page" do
      expect(app_client).to receive(:get).with("/app/hook/deliveries?per_page=100").and_return([
        {guid: "3", id: "31", status: "Fail", delivered_at: time + 3}
      ])
      expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: instance_double(Sawyer::Relation, href: "next_url")}))
      expect(Clog).to receive(:emit).with("failed deliveries page limit reached").and_call_original
      expect(Clog).to receive(:emit).with("fetched deliveries").and_wrap_original do |&blk|
        expect(blk.call).to eq(deliveries: {page: 1, since: time, total: 1})
      end

      expect(prog.failed_deliveries(time, 1)).to eq([{guid: "3", id: "31", status: "Fail", delivered_at: time + 3}])
    end
  end
end
