# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../../model/address"

RSpec.describe OidcProvider do
  it ".register registers a new provider" do
    Excon.stub({path: "/.well-known/openid-configuration", method: :get}, {status: 200, body: {registration_endpoint: "https://example.com/register"}.to_json})

    body = {
      client_name: "Ubicloud",
      redirect_uris: ["#{Config.base_url}/auth/0pk8pg19vxe24gbdms7hmw780h/callback"],
      scopes: "openid email"
    }.to_json
    Excon.stub({path: "/register", method: :post, body:}, {status: 201, body: {client_id: "123", client_secret: "456"}.to_json})

    expect(described_class).to receive(:generate_uuid).and_return("9a2d00a7-7d70-8816-82db-4c9e34e1d008")
    oidc_provider = described_class.register("Test", "https://example.com")
    expect(described_class.all).to eq [oidc_provider]
    expect(oidc_provider.url).to eq "https://example.com"
    expect(oidc_provider.client_id).to eq "123"
    expect(oidc_provider.client_secret).to eq "456"
  end

  it ".register handles errors registering a new provider" do
    Excon.stub({path: "/.well-known/openid-configuration", method: :get}, {status: 200, body: {registration_endpoint: "https://example.com/register"}.to_json})

    body = {
      client_name: "Ubicloud",
      redirect_uris: ["#{Config.base_url}/auth/0pk8pg19vxe24gbdms7hmw780h/callback"],
      scopes: "openid email"
    }.to_json
    Excon.stub({path: "/register", method: :post, body:}, {status: 403, body: {error: "bad"}.to_json})

    expect(described_class).to receive(:generate_uuid).and_return("9a2d00a7-7d70-8816-82db-4c9e34e1d008")
    expect { described_class.register("Test", "https://example.com") }.to raise_error(RuntimeError, 'Unable to register with oidc provider: 403 {"error" => "bad"}')
  end
end
