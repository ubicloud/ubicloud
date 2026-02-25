# frozen_string_literal: true

RSpec.describe CloudflareR2 do
  before do
    allow(Config).to receive_messages(
      cloudflare_r2_api_token: "test-api-token",
      cloudflare_account_id: "test-account-id"
    )
    # Reset cached parent access key ID between tests
    described_class.instance_variable_set(:@parent_access_key_id, nil)
  end

  describe ".generate_temp_credentials" do
    before do
      stub_request(:get, "https://api.cloudflare.com/client/v4/user/tokens/verify")
        .with(headers: {"Authorization" => "Bearer test-api-token"})
        .to_return(status: 200, body: {success: true, result: {id: "test-parent-key-id"}}.to_json)
    end

    it "generates temporary S3 credentials via Cloudflare API" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/accounts/test-account-id/r2/temp-access-credentials")
        .with(
          body: {bucket: "test-bucket", parentAccessKeyId: "test-parent-key-id", permission: "object-read-only", ttlSeconds: 3600}.to_json,
          headers: {"Authorization" => "Bearer test-api-token", "Content-Type" => "application/json"}
        )
        .to_return(
          status: 200,
          body: {
            success: true,
            result: {accessKeyId: "temp-key", secretAccessKey: "temp-secret", sessionToken: "temp-token"}
          }.to_json
        )

      creds = described_class.generate_temp_credentials(bucket: "test-bucket", permission: "object-read-only", ttl_seconds: 3600)
      expect(creds[:access_key_id]).to eq("temp-key")
      expect(creds[:secret_access_key]).to eq("temp-secret")
      expect(creds[:session_token]).to eq("temp-token")
    end

    it "uses default TTL of 86400 seconds" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/accounts/test-account-id/r2/temp-access-credentials")
        .with(
          body: {bucket: "test-bucket", parentAccessKeyId: "test-parent-key-id", permission: "object-read-only", ttlSeconds: 86400}.to_json,
          headers: {"Authorization" => "Bearer test-api-token", "Content-Type" => "application/json"}
        )
        .to_return(
          status: 200,
          body: {
            success: true,
            result: {accessKeyId: "k", secretAccessKey: "s", sessionToken: "t"}
          }.to_json
        )

      creds = described_class.generate_temp_credentials(bucket: "test-bucket", permission: "object-read-only")
      expect(creds[:access_key_id]).to eq("k")
    end

    it "raises on API error" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/accounts/test-account-id/r2/temp-access-credentials")
        .to_return(status: 403, body: {success: false, errors: [{message: "forbidden"}]}.to_json)

      expect {
        described_class.generate_temp_credentials(bucket: "test-bucket", permission: "object-read-write", ttl_seconds: 900)
      }.to raise_error(Excon::Error::Forbidden)
    end

    it "caches the parent access key ID across calls" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/accounts/test-account-id/r2/temp-access-credentials")
        .to_return(
          status: 200,
          body: {success: true, result: {accessKeyId: "k", secretAccessKey: "s", sessionToken: "t"}}.to_json
        )

      described_class.generate_temp_credentials(bucket: "b", permission: "object-read-only", ttl_seconds: 60)
      described_class.generate_temp_credentials(bucket: "b", permission: "object-read-only", ttl_seconds: 60)

      expect(WebMock).to have_requested(:get, "https://api.cloudflare.com/client/v4/user/tokens/verify").once
    end
  end

  describe ".parent_access_key_id" do
    it "derives the access key ID from the API token" do
      stub_request(:get, "https://api.cloudflare.com/client/v4/user/tokens/verify")
        .with(headers: {"Authorization" => "Bearer test-api-token"})
        .to_return(status: 200, body: {success: true, result: {id: "derived-key-id"}}.to_json)

      expect(described_class.parent_access_key_id("test-api-token")).to eq("derived-key-id")
    end

    it "raises on verification failure" do
      stub_request(:get, "https://api.cloudflare.com/client/v4/user/tokens/verify")
        .to_return(status: 401, body: {success: false}.to_json)

      expect {
        described_class.parent_access_key_id("bad-token")
      }.to raise_error(Excon::Error::Unauthorized)
    end
  end
end
