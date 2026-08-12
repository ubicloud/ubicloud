# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe OidcProvider do
  let(:registration_body) do
    {
      issuer: "https://host/issuer",
      authorization_endpoint: "https://host/auth",
      token_endpoint: "https://host/tok",
      userinfo_endpoint: "https://host/ui",
      jwks_uri: "https://host/jw",
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
      jwks_uri: "https://host/jw",
    )
    expect(described_class.name_for_ubid(provider.ubid)).to eq "TestOIDC"
  end

  it ".register registers a new provider with given client_id and client_secret" do
    stub_request(:get, "https://example.com/.well-known/openid-configuration").to_return(status: 200, body: registration_body)
    %w[https://example.com/.well-known/openid-configuration https://example.com].each do |url|
      oidc_provider = described_class.register("Test", url, client_id: "123", client_secret: "456")
      expect(oidc_provider.url).to eq "https://host/issuer"
      expect(oidc_provider.client_id).to eq "123"
      expect(oidc_provider.client_secret).to eq "456"
      expect(oidc_provider.authorization_endpoint).to eq "/auth"
      expect(oidc_provider.token_endpoint).to eq "/tok"
      expect(oidc_provider.userinfo_endpoint).to eq "/ui"
      expect(oidc_provider.jwks_uri).to eq "https://host/jw"
      expect(oidc_provider.registration_client_uri).to be_nil
      expect(oidc_provider.registration_access_token).to be_nil
    end
    expect(described_class.count).to eq 2
  end
end
