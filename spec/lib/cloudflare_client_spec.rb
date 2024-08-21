# frozen_string_literal: true

RSpec.describe CloudflareClient do
  let(:client) { described_class.new("api_key") }

  it "create_temporary_token" do
    expect(Config).to receive(:github_cache_blob_storage_account_id).and_return("account-123")
    Excon.stub({path: "/client/v4/accounts/account-123/r2/temp-access-credentials", method: :post},
      {status: 200, body: {result: {accessKeyId: "123", secretAccessKey: "secret", sessionToken: "token"}}.to_json})
    expect(client.create_temporary_token("bucket", "object-read-write", 123)).to eq(["123", "secret", "token"])
  end
end
