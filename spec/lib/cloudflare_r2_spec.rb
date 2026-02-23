# frozen_string_literal: true

RSpec.describe CloudflareR2 do
  before do
    allow(Config).to receive(:cloudflare_account_id).and_return("test-account-123")
    allow(Config).to receive(:cloudflare_r2_api_token).and_return("test-api-token")
    allow(Config).to receive(:cloudflare_r2_parent_access_key_id).and_return("parent-key-id")
  end

  it "creates temporary credentials with read-only access by default" do
    Excon.stub(
      {path: "/client/v4/accounts/test-account-123/r2/temp-access-credentials", method: :post},
      {status: 200, body: {
        success: true,
        result: {
          "accessKeyId" => "temp-ak",
          "secretAccessKey" => "temp-sk",
          "sessionToken" => "temp-st"
        }
      }.to_json}
    )

    creds = described_class.create_temporary_credentials(bucket: "ubi-images", prefix: "images/abc")
    expect(creds[:access_key_id]).to eq("temp-ak")
    expect(creds[:secret_access_key]).to eq("temp-sk")
    expect(creds[:session_token]).to eq("temp-st")
  end

  it "passes bucket and prefix to the API" do
    request_body = nil
    Excon.stub(
      {path: "/client/v4/accounts/test-account-123/r2/temp-access-credentials", method: :post}
    ) do |params|
      request_body = JSON.parse(params[:body])
      {status: 200, body: {
        success: true,
        result: {"accessKeyId" => "ak", "secretAccessKey" => "sk", "sessionToken" => "st"}
      }.to_json}
    end

    described_class.create_temporary_credentials(bucket: "my-bucket", prefix: "my/prefix/")
    expect(request_body["bucket"]).to eq("my-bucket")
    expect(request_body["prefix"]).to eq("my/prefix/")
    expect(request_body["parentAccessKeyId"]).to eq("parent-key-id")
    expect(request_body["permission"]).to eq("object-read-only")
    expect(request_body["ttlSeconds"]).to eq(3600)
  end

  it "supports read-write permission" do
    request_body = nil
    Excon.stub(
      {path: "/client/v4/accounts/test-account-123/r2/temp-access-credentials", method: :post}
    ) do |params|
      request_body = JSON.parse(params[:body])
      {status: 200, body: {
        success: true,
        result: {"accessKeyId" => "ak", "secretAccessKey" => "sk", "sessionToken" => "st"}
      }.to_json}
    end

    described_class.create_temporary_credentials(bucket: "b", permission: "object-read-write")
    expect(request_body["permission"]).to eq("object-read-write")
  end

  it "allows custom TTL" do
    request_body = nil
    Excon.stub(
      {path: "/client/v4/accounts/test-account-123/r2/temp-access-credentials", method: :post}
    ) do |params|
      request_body = JSON.parse(params[:body])
      {status: 200, body: {
        success: true,
        result: {"accessKeyId" => "ak", "secretAccessKey" => "sk", "sessionToken" => "st"}
      }.to_json}
    end

    described_class.create_temporary_credentials(bucket: "b", ttl_seconds: 3600)
    expect(request_body["ttlSeconds"]).to eq(3600)
    expect(request_body).not_to have_key("prefix")
  end

  it "raises on API failure" do
    Excon.stub(
      {path: "/client/v4/accounts/test-account-123/r2/temp-access-credentials", method: :post},
      {status: 200, body: {
        success: false,
        errors: [{"message" => "Invalid parent key"}]
      }.to_json}
    )

    expect {
      described_class.create_temporary_credentials(bucket: "b")
    }.to raise_error(RuntimeError, /Invalid parent key/)
  end
end
