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

  it ".discovery_attributes returns the column values without creating a row" do
    stub_request(:get, "https://example.com/.well-known/openid-configuration").to_return(status: 200, body: registration_body)
    attrs = described_class.discovery_attributes("Test", "https://example.com", client_id: "123", client_secret: "456")
    expect(attrs).to eq(
      display_name: "Test",
      url: "https://host/issuer",
      client_id: "123",
      client_secret: "456",
      authorization_endpoint: "/auth",
      token_endpoint: "/tok",
      userinfo_endpoint: "/ui",
      jwks_uri: "https://host/jw",
      group_prefix: nil,
      pkce_supported: false,
    )
    expect(described_class.count).to eq 0
  end

  it ".discovery_attributes detects S256 PKCE support from the discovery document" do
    body = JSON.parse(registration_body).merge("code_challenge_methods_supported" => ["plain", "S256"]).to_json
    stub_request(:get, "https://example.com/.well-known/openid-configuration").to_return(status: 200, body:)
    attrs = described_class.discovery_attributes("Test", "https://example.com", client_id: "123", client_secret: "456")
    expect(attrs[:pkce_supported]).to be true
  end

  describe "#refresh_groups" do
    let(:provider) do
      described_class.create(
        display_name: "Test",
        client_id: "123",
        client_secret: "456",
        url: "https://host/issuer",
        authorization_endpoint: "/auth",
        token_endpoint: "/tok",
        userinfo_endpoint: "/ui",
        jwks_uri: "https://host/jw",
        group_prefix: "oidc-",
        groups_claim: "app:groups",
      )
    end

    def id_token(**claims)
      JWT.encode({sub: "u1", iss: "https://host/issuer", aud: "123"}.merge(claims), nil, "none")
    end

    it "returns groups from the id token claim and the rotated refresh token" do
      stub_request(:post, "https://host/tok").with(body: {grant_type: "refresh_token", refresh_token: "old-rt"})
        .to_return(status: 200, body: {id_token: id_token("app:groups": ["G1", 2]), refresh_token: "new-rt"}.to_json)
      expect(provider.refresh_groups("old-rt")).to eq [["G1", "2"], "new-rt"]
    end

    it "returns nil refresh_token when the response doesn't rotate it" do
      stub_request(:post, "https://host/tok").to_return(status: 200, body: {id_token: id_token("app:groups": "G1")}.to_json)
      expect(provider.refresh_groups("old-rt")).to eq [["G1"], nil]
    end

    it "accepts an array aud containing the client_id" do
      stub_request(:post, "https://host/tok").to_return(status: 200, body: {id_token: id_token(aud: ["other", "123"], "app:groups": ["G1"])}.to_json)
      expect(provider.refresh_groups("old-rt")).to eq [["G1"], nil]
    end

    it "falls back to userinfo when the id token lacks the groups claim" do
      stub_request(:post, "https://host/tok").to_return(status: 200, body: {id_token:, access_token: "at"}.to_json)
      stub_request(:get, "https://host/ui").with(headers: {"Authorization" => "Bearer at"})
        .to_return(status: 200, body: {"app:groups" => ["G2"]}.to_json)
      expect(provider.refresh_groups("old-rt")).to eq [["G2"], nil]
    end

    it "returns no groups when neither the id token nor userinfo has the claim" do
      stub_request(:post, "https://host/tok").to_return(status: 200, body: {id_token:, access_token: "at"}.to_json)
      stub_request(:get, "https://host/ui").to_return(status: 200, body: {sub: "u1"}.to_json)
      expect(provider.refresh_groups("old-rt")).to eq [[], nil]
    end

    it "raises RefreshError when userinfo fails" do
      stub_request(:post, "https://host/tok").to_return(status: 200, body: {id_token:, access_token: "at"}.to_json)
      stub_request(:get, "https://host/ui").to_return(status: 500, body: "")
      expect { provider.refresh_groups("old-rt") }.to raise_error(described_class::RefreshError)
    end

    it "raises RefreshError when the issuer doesn't match" do
      stub_request(:post, "https://host/tok").to_return(status: 200, body: {id_token: id_token(iss: "https://evil.example.com")}.to_json)
      expect { provider.refresh_groups("old-rt") }.to raise_error(described_class::RefreshError)
    end

    it "raises RefreshError when the audience doesn't include client_id" do
      stub_request(:post, "https://host/tok").to_return(status: 200, body: {id_token: id_token(aud: "someone-else")}.to_json)
      expect { provider.refresh_groups("old-rt") }.to raise_error(described_class::RefreshError)
    end

    it "returns nil when the refresh token is rejected" do
      stub_request(:post, "https://host/tok").to_return(status: 400, body: {error: "invalid_grant"}.to_json)
      expect(provider.refresh_groups("old-rt")).to be_nil
    end

    it "raises RefreshError on a 400 that isn't invalid_grant" do
      stub_request(:post, "https://host/tok").to_return(status: 400, body: {error: "invalid_client"}.to_json)
      expect { provider.refresh_groups("old-rt") }.to raise_error(described_class::RefreshError)
    end

    it "raises RefreshError on an unexpected status" do
      stub_request(:post, "https://host/tok").to_return(status: 500, body: "")
      expect { provider.refresh_groups("old-rt") }.to raise_error(described_class::RefreshError)
    end

    it "raises RefreshError on a network error" do
      stub_request(:post, "https://host/tok").to_timeout
      expect { provider.refresh_groups("old-rt") }.to raise_error(described_class::RefreshError)
    end

    it "raises RefreshError on a malformed response" do
      stub_request(:post, "https://host/tok").to_return(status: 200, body: "not json")
      expect { provider.refresh_groups("old-rt") }.to raise_error(described_class::RefreshError)
    end
  end
end
