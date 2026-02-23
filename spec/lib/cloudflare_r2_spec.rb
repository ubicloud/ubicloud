# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe CloudflareR2 do
  before do
    allow(Config).to receive_messages(
      machine_image_r2_api_token: "test-api-token",
      machine_image_r2_account_id: "test-account-id",
      machine_image_r2_access_key_id: "test-parent-key-id"
    )
  end

  describe ".generate_temp_credentials" do
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

    it "raises on API error" do
      stub_request(:post, "https://api.cloudflare.com/client/v4/accounts/test-account-id/r2/temp-access-credentials")
        .to_return(status: 403, body: {success: false, errors: [{message: "forbidden"}]}.to_json)

      expect {
        described_class.generate_temp_credentials(bucket: "test-bucket", permission: "object-read-write", ttl_seconds: 900)
      }.to raise_error(Excon::Error::Forbidden)
    end
  end
end
