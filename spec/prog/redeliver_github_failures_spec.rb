# frozen_string_literal: true

require_relative "../model/spec_helper"
require "octokit"

RSpec.describe Prog::RedeliverGithubFailures do
  subject(:prog) {
    described_class.new(Strand.create(prog: "RedeliverGithubFailures", label: "wait", stack: [{"last_check_at" => "2023-10-19 22:27:47 UTC"}]))
  }

  let(:time) { Time.utc(2023, 10, 19, 22, 27, 47) }
  let(:app_client) { instance_double(Octokit::Client) }

  before do
    allow(Github).to receive(:app_client).and_return(app_client)
  end

  describe "#wait" do
    it "naps if last check was less than 2 minutes ago" do
      expect(Time).to receive(:now).and_return(time + 50).at_least(:once)
      expect { prog.wait }.to nap(71)
    end

    it "buds redelivery children and hops" do
      expect(Time).to receive(:now).and_return(time + 60 * 60).at_least(:once)
      expect(prog).to receive(:failed_deliveries).with(time).and_return(
        Array.new(26).map.with_index(1) { |_, i| {guid: i, id: i, status: "Fail", delivered_at: time + 5} }
      )
      expect { prog.wait }.to hop("wait_redelivers")
        .and change { prog.strand.stack.first["last_check_at"] }.from("2023-10-19 22:27:47 UTC").to("2023-10-19 23:27:47 UTC")
        .and change(Strand, :count).by(2)
      expect(prog.strand.children.count).to eq(2)
      expect(prog.strand.children.map { it.stack.first["delivery_ids"] }).to include([26])
    end
  end

  describe "#wait_redelivers" do
    it "registers deadline and reaps wait" do
      expect(prog).to receive(:register_deadline).with("wait", 10 * 60)
      expect { prog.wait_redelivers }.to hop("wait")
    end
  end

  describe "#redeliver" do
    it "redelivers the given delivery ids" do
      expect(prog).to receive(:frame).and_return({"delivery_ids" => ["11", "21"]}).at_least(:once)
      expect(app_client).to receive(:post).with("/app/hook/deliveries/11/attempts")
      expect(app_client).to receive(:post).with("/app/hook/deliveries/21/attempts")
      expect { prog.redeliver }.to exit({"msg" => "redelivered failures"})
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
        {guid: "2", id: "21", status: "OK", delivered_at: time + 3},
        {guid: "3", id: "31", status: "Fail", delivered_at: time + 3}
      ])
      expect(app_client).to receive(:last_response).and_return(instance_double(Sawyer::Response, rels: {next: instance_double(Sawyer::Relation, href: "next_url")}))
      expect(Clog).to receive(:emit).with("fetched github deliveries").and_wrap_original do |&blk|
        expect(blk.call).to eq(fetched_github_deliveries: {total: 2, failed: 1, status: {"Fail" => 1}, page: 1, since: time})
      end

      expect(prog.failed_deliveries(time, 1)).to eq([{guid: "3", id: "31", status: "Fail", delivered_at: time + 3}])
    end
  end
end
