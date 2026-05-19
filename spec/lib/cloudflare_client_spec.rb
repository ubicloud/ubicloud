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

    it "create_dns_record returns the new record id" do
      Excon.stub(
        {path: "/client/v4/zones/#{zone_id}/dns_records", method: :post, body: {type: "A", name: "ns1.example.com", content: "1.2.3.4", ttl: 60, proxied: false}.to_json},
        {status: 200, body: {result: {id: "rec1"}}.to_json},
      )
      expect(client.create_dns_record(zone_id, type: "A", name: "ns1.example.com", content: "1.2.3.4")).to eq("rec1")
    end

    it "delete_dns_record returns the response status" do
      Excon.stub({path: "/client/v4/zones/#{zone_id}/dns_records/rec1", method: :delete}, {status: 200})
      expect(client.delete_dns_record(zone_id, "rec1")).to eq(200)
    end

    it "delete_dns_record tolerates 404 for already-removed records" do
      Excon.stub({path: "/client/v4/zones/#{zone_id}/dns_records/gone", method: :delete}, {status: 404})
      expect(client.delete_dns_record(zone_id, "gone")).to eq(404)
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
