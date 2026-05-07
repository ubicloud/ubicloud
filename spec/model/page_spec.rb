# frozen_string_literal: true

require_relative "spec_helper"

require "json"
require "pagerduty"

RSpec.describe Page do
  subject(:p) { described_class.create(tag: "dummy-tag") }

  if Config.unfrozen_test?
    after do
      described_class.instance_variable_set(:@client, nil)
    end
  end

  describe ".root_resources" do
    it "returns array of root resource ids for the related object" do
      expect(described_class.root_resources(Nic.new)).to eq []

      gi = GithubInstallation.new_with_id(installation_id: 1, name: "foo", type: "bar")
      expect(described_class.root_resources(GithubRepository.new(installation: gi))).to eq [gi.id]

      pt = PostgresTimeline.create(location_id: Location::HETZNER_FSN1_ID, access_key: "dummy-access-key", secret_key: "dummy-secret-key")
      expect(described_class.root_resources(pt)).to eq []

      project = Project.create(name: "test")
      pg = create_postgres_resource(project:, location_id: Location::HETZNER_FSN1_ID)
      expect(described_class.root_resources(pg)).to eq [pg.id]

      pv = PostgresServer.create(timeline: pt, resource_id: pg.id, is_representative: false, version: PostgresResource::DEFAULT_VERSION)
      expect(described_class.root_resources(pv)).to eq [pg.id]

      pv = create_postgres_server(resource: pg)
      expect(described_class.root_resources(pv)).to eq [pg.id]
      expect(described_class.root_resources(pv.timeline)).to eq [pg.id]

      pv.vm.update(vm_host_id: create_vm_host.id)
      pv.refresh
      expect(described_class.root_resources(pv)).to eq [pv.vm.vm_host_id, pg.id]
      expect(described_class.root_resources(pv.timeline)).to eq [pv.vm.vm_host_id, pg.id]
    end

    it "returns empty array for exceptions" do
      nic = Nic.new
      expect(nic).to receive(:vm).and_raise(RuntimeError)
      expect(Clog).to receive(:emit).with("error determining root resource for page", instance_of(Hash)).and_call_original
      expect(described_class.root_resources(nic)).to eq []
    end
  end

  context "with pager duty" do
    before do
      expect(Config).to receive(:pagerduty_key).and_return("dummy-key").at_least(:once)
      stub_request(:post, "https://events.pagerduty.com/v2/enqueue")
        .to_return(status: 200, body: {dedup_key: "dummy-dedup-key", message: "Event processed", status: "success"}.to_json, headers: {})
      # reinitialize to setup @client
      p.client.send(:initialize)
    end

    describe "#trigger" do
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
        expect(p.client).to receive(:resolve).and_call_original
        p.resolve
      end
    end
  end

  context "with incident.io" do
    before do
      expect(Config).to receive(:incidentio_key).and_return("dummy-key").at_least(:once)
      expect(Config).to receive(:incidentio_alert_source_config_id).and_return("source-id").at_least(:once)
    end

    describe "#trigger" do
      it "triggers a page if key is present" do
        Excon.stub({
          url: "https://api.incident.io/v2/alert_events/http/source-id",
          method: "post",
          body: {
            deduplication_key: p.client.send(:deduplication_key, p.tag),
            status: "firing",
            title: p.summary,
            source_url: "#{Config.admin_url}/model/Page/#{p.ubid}",
            metadata: {severity: p.severity},
          }.to_json,
          headers: {
            "Authorization" => "Bearer dummy-key",
            "Content-Type" => "application/json",
          },
        }, {status: 202})
        expect(p.trigger.status).to eq(202)
      end

      it "triggers a page with extra links" do
        Excon.stub({
          url: "https://api.incident.io/v2/alert_events/http/source-id",
          method: "post",
          body: {
            deduplication_key: p.client.send(:deduplication_key, p.tag),
            status: "firing",
            title: "title",
            source_url: nil,
            metadata: {
              severity: "low",
              links: ["https://example.com"],
            },
          }.to_json,
          headers: {
            "Authorization" => "Bearer dummy-key",
            "Content-Type" => "application/json",
          },
        }, {status: 202})
        expect(p.client.trigger(p.tag, summary: "title", severity: "low", details: {}, links: [nil, "https://example.com"]).status).to eq(202)
      end
    end

    describe "#resolve" do
      it "resolves the page if key is present" do
        Excon.stub({
          url: "https://api.incident.io/v2/alert_events/http/source-id",
          method: "post",
          body: {
            deduplication_key: p.client.send(:deduplication_key, p.tag),
            status: "resolved",
            title: p.summary,
          }.to_json,
          headers: {
            "Authorization" => "Bearer dummy-key",
            "Content-Type" => "application/json",
          },
        }, {status: 202})
        expect(p.resolve.status).to eq(202)
      end
    end
  end

  context "without any api" do
    describe "#trigger" do
      it "triggers a page if key is present" do
        expect(Clog).to receive(:emit).with("page triggered", {page_triggered: {
          tag: p.tag,
          summary: p.summary,
          severity: p.severity,
          details: p.details,
          links: [{href: "#{Config.admin_url}/model/Page/#{p.ubid}", text: "Admin Page"}],
        }})
        p.trigger
      end
    end

    describe "#resolve" do
      it "resolves the page if key is present" do
        expect(Clog).to receive(:emit).with("page resolved", {page_resolved: {
          tag: p.tag,
        }})
        p.resolve
      end
    end
  end

  describe ".severity_order" do
    it "returns the correct order for severity levels" do
      expect(described_class.severity_order("info")).to eq(0)
      expect(described_class.severity_order("warning")).to eq(1)
      expect(described_class.severity_order("error")).to eq(2)
      expect(described_class.severity_order("critical")).to eq(3)
    end

    it "raises an error for unknown severity" do
      expect { described_class.severity_order("unknown") }.to raise_error(KeyError)
    end
  end
end
