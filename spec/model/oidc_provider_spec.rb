# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../../model/address"

RSpec.describe OidcProvider do
  let(:registration_body) do
    {
      registration_endpoint: "https://example.com/register",
      authorization_endpoint: "https://host/auth",
      token_endpoint: "https://host/tok",
      userinfo_endpoint: "https://host/ui",
      jwks_uri: "https://host/jw"
    }.to_json
  end

  it ".name_for_ubid returns the name for the provider, if there is one" do
    expect(described_class.name_for_ubid(described_class.generate_ubid.to_s)).to be_nil
    provider = described_class.create(
      display_name: "TestOIDC",
      client_id: "123",
      client_secret: "456",
      url: "http://example.com",
      authorization_endpoint: "/auth",
      token_endpoint: "/tok",
      userinfo_endpoint: "/ui",
      jwks_uri: "https://host/jw"
    )
    expect(described_class.name_for_ubid(provider.ubid)).to eq "TestOIDC"
  end

  it ".register registers a new provider" do
    Excon.stub({path: "/.well-known/openid-configuration", method: :get}, {status: 200, body: registration_body})

    request_body = {
      client_name: "Ubicloud",
      redirect_uris: ["#{Config.base_url}/auth/0pk8pg19vxe24gbdms7hmw780h/callback"],
      scopes: "openid email"
    }.to_json
    response_body = {
      client_id: "123",
      client_secret: "456",
      registration_client_uri: "https://host/rc",
      registration_access_token: "789"
    }.to_json
    Excon.stub({path: "/register", method: :post, body: request_body}, {status: 201, body: response_body})

    expect(described_class).to receive(:generate_uuid).and_return("9a2d00a7-7d70-8816-82db-4c9e34e1d008")
    oidc_provider = described_class.register("Test", "https://example.com")
    expect(described_class.all).to eq [oidc_provider]
    expect(oidc_provider.url).to eq "https://example.com"
    expect(oidc_provider.client_id).to eq "123"
    expect(oidc_provider.client_secret).to eq "456"
    expect(oidc_provider.authorization_endpoint).to eq "/auth"
    expect(oidc_provider.token_endpoint).to eq "/tok"
    expect(oidc_provider.userinfo_endpoint).to eq "/ui"
    expect(oidc_provider.jwks_uri).to eq "https://host/jw"
    expect(oidc_provider.registration_client_uri).to eq "https://host/rc"
    expect(oidc_provider.registration_access_token).to eq "789"
  end

  it ".register registers a new provider with given client_id and client_secret" do
    Excon.stub({path: "/.well-known/openid-configuration", method: :get}, {status: 200, body: registration_body})
    expect(described_class).to receive(:generate_uuid).and_return("9a2d00a7-7d70-8816-82db-4c9e34e1d008")
    oidc_provider = described_class.register("Test", "https://example.com", client_id: "123", client_secret: "456")
    expect(described_class.all).to eq [oidc_provider]
    expect(oidc_provider.url).to eq "https://example.com"
    expect(oidc_provider.client_id).to eq "123"
    expect(oidc_provider.client_secret).to eq "456"
    expect(oidc_provider.authorization_endpoint).to eq "/auth"
    expect(oidc_provider.token_endpoint).to eq "/tok"
    expect(oidc_provider.userinfo_endpoint).to eq "/ui"
    expect(oidc_provider.jwks_uri).to eq "https://host/jw"
    expect(oidc_provider.registration_client_uri).to be_nil
    expect(oidc_provider.registration_access_token).to be_nil
  end

  it ".register handles errors registering a new provider" do
    Excon.stub({path: "/.well-known/openid-configuration", method: :get}, {status: 200, body: registration_body})

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
