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
end
