# frozen_string_literal: true

RSpec.describe CloudflareClient do
  let(:client) { described_class.new("api_key") }

  it "create_token" do
    stub_request(:post, "https://api.cloudflare.com/client/v4/user/tokens").to_return(status: 200, body: {result: {id: "123", value: "secret"}}.to_json)
    expect(client.create_token("test-token", [{id: "test-policy"}])).to eq(["123", "secret"])
  end

  it "delete_token" do
    token_id = "123"
    stub_request(:delete, "https://api.cloudflare.com/client/v4/user/tokens/#{token_id}").to_return(status: 200)
    expect(client.delete_token(token_id)).to eq(200)
  end

  describe "DNS records" do
    let(:zone_id) { "abc123" }

    it "zone_id_by_name returns the zone id" do
      stub_request(:get, "https://api.cloudflare.com/client/v4/zones").with(query: {name: "tahcloud.com"}).to_return(status: 200, body: {result: [{id: zone_id, name: "tahcloud.com"}]}.to_json)
      expect(client.zone_id_by_name("tahcloud.com")).to eq(zone_id)
    end

    it "zone_id_by_name raises when no zone is found" do
      stub_request(:get, "https://api.cloudflare.com/client/v4/zones").with(query: {name: "missing.com"}).to_return(status: 200, body: {result: []}.to_json)
      expect { client.zone_id_by_name("missing.com") }.to raise_error(RuntimeError, /Cloudflare zone not found: missing.com/)
    end

    describe "#ensure_dns_record" do
      let(:name) { "ns-e2e.example.com" }
      let(:list_url) { "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records" }
      let(:create_body) { {type: "A", name:, content: "1.2.3.4", ttl: 60, proxied: false}.to_json }

      it "returns the existing record id when an exact match is found" do
        stub_request(:get, list_url).with(query: {name:, type: "A"})
          .to_return(status: 200, body: {result: [{id: "rec1", content: "1.2.3.4", ttl: 60, proxied: false}]}.to_json)
        expect(client.ensure_dns_record(zone_id, type: "A", name:, content: "1.2.3.4")).to eq("rec1")
      end

      it "creates a new record when none exist" do
        stub_request(:get, list_url).with(query: {name:, type: "A"}).to_return(status: 200, body: {result: []}.to_json)
        stub_request(:post, list_url).with(body: create_body).to_return(status: 200, body: {result: {id: "new-rec"}}.to_json)
        expect(client.ensure_dns_record(zone_id, type: "A", name:, content: "1.2.3.4")).to eq("new-rec")
      end

      it "deletes a record that differs and creates a fresh one" do
        stub_request(:get, list_url).with(query: {name:, type: "A"})
          .to_return(status: 200, body: {result: [{id: "stale", content: "9.9.9.9", ttl: 60, proxied: false}]}.to_json)
        stub_request(:delete, "#{list_url}/stale").to_return(status: 200)
        stub_request(:post, list_url).with(body: create_body).to_return(status: 200, body: {result: {id: "new-rec"}}.to_json)
        expect(client.ensure_dns_record(zone_id, type: "A", name:, content: "1.2.3.4")).to eq("new-rec")
      end

      it "deletes every non-matching record but keeps and returns the matching one" do
        stub_request(:get, list_url).with(query: {name:, type: "A"})
          .to_return(status: 200, body: {result: [
            {id: "stale-1", content: "9.9.9.9", ttl: 60, proxied: false},
            {id: "keep", content: "1.2.3.4", ttl: 60, proxied: false},
            {id: "stale-2", content: "8.8.8.8", ttl: 60, proxied: false},
          ]}.to_json)
        stub_request(:delete, "#{list_url}/stale-1").to_return(status: 200)
        stub_request(:delete, "#{list_url}/stale-2").to_return(status: 200)
        expect(client.ensure_dns_record(zone_id, type: "A", name:, content: "1.2.3.4")).to eq("keep")
      end
    end

    it "delete_dns_record returns the response status" do
      stub_request(:delete, "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records/rec1").to_return(status: 200)
      expect(client.delete_dns_record(zone_id, "rec1")).to eq(200)
    end

    it "delete_dns_record tolerates 404 for already-removed records" do
      stub_request(:delete, "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records/gone").to_return(status: 404)
      expect(client.delete_dns_record(zone_id, "gone")).to eq(404)
    end

    it "delete_dns_records deletes each id in turn" do
      stub_request(:delete, "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records/a").to_return(status: 200)
      stub_request(:delete, "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records/b").to_return(status: 200)
      stub_request(:delete, "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records/c").to_return(status: 200)
      expect { client.delete_dns_records(zone_id, ["a", "b", "c"]) }.not_to raise_error
    end
  end

  describe "when setting Config.github_cache_blob_storage_use_account_token" do
    before do
      expect(Config).to receive(:github_cache_blob_storage_use_account_token).and_return(true)
      expect(Config).to receive(:github_cache_blob_storage_account_id).and_return("XYZ")
    end

    it "create_token" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/accounts/XYZ/tokens").to_return(status: 200, body: {result: {id: "123", value: "secret"}}.to_json)
      expect(client.create_token("test-token", [{id: "test-policy"}])).to eq(["123", "secret"])
    end

    it "delete_token" do
      token_id = "123"
      stub_request(:delete, "https://api.cloudflare.com/client/v4/accounts/XYZ/tokens/#{token_id}").to_return(status: 200)
      expect(client.delete_token(token_id)).to eq(200)
    end
  end
end
