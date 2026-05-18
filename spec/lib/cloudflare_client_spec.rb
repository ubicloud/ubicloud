# frozen_string_literal: true

RSpec.describe CloudflareClient do
  let(:client) { described_class.new("api_key") }

  it "create_token" do
    Excon.stub({path: "/client/v4/user/tokens", method: :post}, {status: 200, body: {result: {id: "123", value: "secret"}}.to_json})
    expect(client.create_token("test-token", [{id: "test-policy"}])).to eq(["123", "secret"])
  end

  it "delete_token" do
    token_id = "123"
    Excon.stub({path: "/client/v4/user/tokens/#{token_id}", method: :delete}, {status: 200})
    expect(client.delete_token(token_id)).to eq(200)
  end

  describe "DNS records" do
    let(:zone_id) { "abc123" }

    it "zone_id_by_name returns the zone id" do
      Excon.stub({path: "/client/v4/zones", method: :get, query: {name: "tahcloud.com"}}, {status: 200, body: {result: [{id: zone_id, name: "tahcloud.com"}]}.to_json})
      expect(client.zone_id_by_name("tahcloud.com")).to eq(zone_id)
    end

    it "zone_id_by_name raises when no zone is found" do
      Excon.stub({path: "/client/v4/zones", method: :get, query: {name: "missing.com"}}, {status: 200, body: {result: []}.to_json})
      expect { client.zone_id_by_name("missing.com") }.to raise_error(RuntimeError, /Cloudflare zone not found: missing.com/)
    end

    describe "#ensure_dns_record" do
      let(:name) { "ns-e2e.example.com" }
      let(:list_path) { "/client/v4/zones/#{zone_id}/dns_records" }
      let(:create_body) { {type: "A", name:, content: "1.2.3.4", ttl: 60, proxied: false}.to_json }

      it "returns the existing record id when an exact match is found" do
        Excon.stub(
          {path: list_path, method: :get, query: {name:, type: "A"}},
          {status: 200, body: {result: [{id: "rec1", content: "1.2.3.4", ttl: 60, proxied: false}]}.to_json},
        )
        expect(client.ensure_dns_record(zone_id, type: "A", name:, content: "1.2.3.4")).to eq("rec1")
      end

      it "creates a new record when none exist" do
        Excon.stub({path: list_path, method: :get, query: {name:, type: "A"}}, {status: 200, body: {result: []}.to_json})
        Excon.stub({path: list_path, method: :post, body: create_body}, {status: 200, body: {result: {id: "new-rec"}}.to_json})
        expect(client.ensure_dns_record(zone_id, type: "A", name:, content: "1.2.3.4")).to eq("new-rec")
      end

      it "deletes a record that differs and creates a fresh one" do
        Excon.stub(
          {path: list_path, method: :get, query: {name:, type: "A"}},
          {status: 200, body: {result: [{id: "stale", content: "9.9.9.9", ttl: 60, proxied: false}]}.to_json},
        )
        Excon.stub({path: "#{list_path}/stale", method: :delete}, {status: 200})
        Excon.stub({path: list_path, method: :post, body: create_body}, {status: 200, body: {result: {id: "new-rec"}}.to_json})
        expect(client.ensure_dns_record(zone_id, type: "A", name:, content: "1.2.3.4")).to eq("new-rec")
      end

      it "deletes every non-matching record but keeps and returns the matching one" do
        Excon.stub(
          {path: list_path, method: :get, query: {name:, type: "A"}},
          {status: 200, body: {result: [
            {id: "stale-1", content: "9.9.9.9", ttl: 60, proxied: false},
            {id: "keep", content: "1.2.3.4", ttl: 60, proxied: false},
            {id: "stale-2", content: "8.8.8.8", ttl: 60, proxied: false},
          ]}.to_json},
        )
        Excon.stub({path: "#{list_path}/stale-1", method: :delete}, {status: 200})
        Excon.stub({path: "#{list_path}/stale-2", method: :delete}, {status: 200})
        expect(client.ensure_dns_record(zone_id, type: "A", name:, content: "1.2.3.4")).to eq("keep")
      end
    end

    it "delete_dns_record returns the response status" do
      Excon.stub({path: "/client/v4/zones/#{zone_id}/dns_records/rec1", method: :delete}, {status: 200})
      expect(client.delete_dns_record(zone_id, "rec1")).to eq(200)
    end

    it "delete_dns_record tolerates 404 for already-removed records" do
      Excon.stub({path: "/client/v4/zones/#{zone_id}/dns_records/gone", method: :delete}, {status: 404})
      expect(client.delete_dns_record(zone_id, "gone")).to eq(404)
    end

    it "delete_dns_records deletes each id in turn" do
      Excon.stub({path: "/client/v4/zones/#{zone_id}/dns_records/a", method: :delete}, {status: 200})
      Excon.stub({path: "/client/v4/zones/#{zone_id}/dns_records/b", method: :delete}, {status: 200})
      Excon.stub({path: "/client/v4/zones/#{zone_id}/dns_records/c", method: :delete}, {status: 200})
      expect { client.delete_dns_records(zone_id, ["a", "b", "c"]) }.not_to raise_error
    end
  end

  describe "when setting Config.github_cache_blob_storage_use_account_token" do
    before do
      expect(Config).to receive(:github_cache_blob_storage_use_account_token).and_return(true)
      expect(Config).to receive(:github_cache_blob_storage_account_id).and_return("XYZ")
    end

    it "create_token" do
      Excon.stub({path: "/client/v4/accounts/XYZ/tokens", method: :post}, {status: 200, body: {result: {id: "123", value: "secret"}}.to_json})
      expect(client.create_token("test-token", [{id: "test-policy"}])).to eq(["123", "secret"])
    end

    it "delete_token" do
      token_id = "123"
      Excon.stub({path: "/client/v4/accounts/XYZ/tokens/#{token_id}", method: :delete}, {status: 200})
      expect(client.delete_token(token_id)).to eq(200)
    end
  end
end
