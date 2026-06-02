# frozen_string_literal: true

require_relative "spec_helper"
require "jwt"

RSpec.describe JwtIssuer do
  let(:project) { Project.create(name: "test-project") }
  let(:account) { Account.create(email: "svc@example.com", status_id: 2) }
  let(:rsa_key) { Clec::Cert.rsa_2048_key }

  let(:issuer) do
    described_class.create(
      project_id: project.id,
      account_id: account.id,
      name: "test-issuer",
      issuer: "https://jwks.example.com",
      jwks_uri: "https://jwks.example.com/.well-known/jwks.json",
    )
  end

  def stub_jwks(uri, key: rsa_key, kid: "k1")
    jwk = JWT::JWK.new(key, kid:)
    stub_request(:get, uri).to_return(body: {keys: [jwk.export]}.to_json)
  end

  def mint(claims = {}, kid: "k1")
    payload = {"iss" => issuer.issuer, "exp" => Time.now.to_i + 300}.merge(claims)
    JWT.encode(payload, rsa_key, "RS256", {kid:})
  end

  before do
    described_class::JWKS_CACHE.clear
  end

  it "decodes JWT via JWKS URI" do
    stub_jwks(issuer.jwks_uri)
    payload = issuer.decode_jwt(mint({"data" => "test"}))
    expect(payload["data"]).to eq("test")
  end

  it "rejects token missing exp claim" do
    stub_jwks(issuer.jwks_uri)
    token = JWT.encode({"iss" => issuer.issuer}, rsa_key, "RS256", {kid: "k1"})
    expect { issuer.decode_jwt(token) }.to raise_error(JWT::MissingRequiredClaim)
  end

  it "rejects expired token" do
    stub_jwks(issuer.jwks_uri)
    token = mint({"exp" => Time.now.to_i - 120})
    expect { issuer.decode_jwt(token) }.to raise_error(JWT::ExpiredSignature)
  end

  it "rejects mismatched issuer" do
    stub_jwks(issuer.jwks_uri)
    token = JWT.encode({"iss" => "https://other.example.com", "exp" => Time.now.to_i + 300}, rsa_key, "RS256", {kid: "k1"})
    expect { issuer.decode_jwt(token) }.to raise_error(JWT::InvalidIssuerError)
  end

  it "caches JWKS across model instances" do
    stub = stub_jwks(issuer.jwks_uri)
    issuer.decode_jwt(mint)
    described_class.first(id: issuer.id).decode_jwt(mint)
    expect(stub).to have_been_requested.once
  end

  it "throttles JWKS refetch on kid miss within min interval, then refetches" do
    stub = stub_jwks(issuer.jwks_uri)
    issuer.decode_jwt(mint)

    token2 = JWT.encode({"iss" => issuer.issuer, "exp" => Time.now.to_i + 300}, rsa_key, "RS256", {kid: "k2"})

    # kid miss within JWKS_MIN_REFETCH serves cache, no extra fetch
    expect { issuer.decode_jwt(token2) }.to raise_error(JWT::DecodeError)
    expect(stub).to have_been_requested.once

    # Process frozen under CLOVER_FREEZE, so age the cached entry instead of stubbing the clock
    described_class::JWKS_CACHE[issuer.jwks_uri][:at] -= described_class::JWKS_MIN_REFETCH + 1

    # past the interval, kid miss forces a refetch
    expect { issuer.decode_jwt(token2) }.to raise_error(JWT::DecodeError)
    expect(stub).to have_been_requested.twice
  end

  it "decodes ES256-signed JWT" do
    ec_key = OpenSSL::PKey::EC.generate("prime256v1")
    stub_request(:get, issuer.jwks_uri).to_return(body: {keys: [JWT::JWK.new(ec_key, kid: "ec1").export]}.to_json)
    token = JWT.encode({"iss" => issuer.issuer, "exp" => Time.now.to_i + 300}, ec_key, "ES256", {kid: "ec1"})
    expect(issuer.decode_jwt(token)["iss"]).to eq(issuer.issuer)
  end

  it "refreshes JWKS after TTL" do
    stub = stub_jwks(issuer.jwks_uri)
    issuer.decode_jwt(mint)

    # Process frozen under CLOVER_FREEZE, so age the cached entry instead of stubbing the clock
    described_class::JWKS_CACHE[issuer.jwks_uri][:at] -= described_class::JWKS_CACHE_TTL + 1

    issuer.decode_jwt(mint)
    expect(stub).to have_been_requested.twice
  end

  it "wraps JWKS fetch errors as JWT::DecodeError" do
    stub_request(:get, issuer.jwks_uri).to_return(status: 500)
    expect { issuer.decode_jwt(mint) }.to raise_error(JWT::DecodeError, /Failed to fetch JWKS/)
  end

  it "wraps malformed JWKS JSON as JWT::DecodeError" do
    stub_request(:get, issuer.jwks_uri).to_return(body: "not json")
    expect { issuer.decode_jwt(mint) }.to raise_error(JWT::DecodeError, /Failed to fetch JWKS/)
  end

  it "allows concurrent fetches to all succeed" do
    stub_jwks(issuer.jwks_uri)
    token = mint
    payloads = Array.new(5) { Thread.new { issuer.decode_jwt(token) } }.map(&:value)
    expect(payloads).to all(include("iss" => issuer.issuer))
  end

  it "does not cache a failed fetch, so the next request retries" do
    stub_request(:get, issuer.jwks_uri)
      .to_return({status: 500}, {body: {keys: [JWT::JWK.new(rsa_key, kid: "k1").export]}.to_json})
    expect { issuer.decode_jwt(mint) }.to raise_error(JWT::DecodeError)
    expect(issuer.decode_jwt(mint)["iss"]).to eq(issuer.issuer)
  end

  describe "audience verification" do
    let(:issuer) do
      described_class.create(
        project_id: project.id,
        account_id: account.id,
        name: "aud-issuer",
        issuer: "https://jwks.example.com",
        jwks_uri: "https://jwks.example.com/.well-known/jwks.json",
        audience: "ubicloud",
      )
    end

    it "accepts matching audience" do
      stub_jwks(issuer.jwks_uri)
      payload = issuer.decode_jwt(mint({"aud" => "ubicloud"}))
      expect(payload["aud"]).to eq("ubicloud")
    end

    it "rejects missing audience" do
      stub_jwks(issuer.jwks_uri)
      expect { issuer.decode_jwt(mint) }.to raise_error(JWT::InvalidAudError)
    end

    it "rejects mismatched audience" do
      stub_jwks(issuer.jwks_uri)
      expect { issuer.decode_jwt(mint({"aud" => "other"})) }.to raise_error(JWT::InvalidAudError)
    end
  end

  describe "validation" do
    let(:base) { {project_id: project.id, account_id: account.id, name: "n", issuer: "https://x"} }

    it "rejects http jwks_uri" do
      expect { described_class.create(base.merge(jwks_uri: "http://example.com/jwks")) }
        .to raise_error(Sequel::ValidationFailed, /jwks_uri/)
    end

    it "rejects loopback jwks_uri" do
      expect { described_class.create(base.merge(jwks_uri: "https://127.0.0.1/jwks")) }
        .to raise_error(Sequel::ValidationFailed, /jwks_uri/)
    end

    it "rejects private ip jwks_uri" do
      expect { described_class.create(base.merge(jwks_uri: "https://10.0.0.1/jwks")) }
        .to raise_error(Sequel::ValidationFailed, /jwks_uri/)
    end

    it "rejects link-local jwks_uri" do
      expect { described_class.create(base.merge(jwks_uri: "https://169.254.169.254/jwks")) }
        .to raise_error(Sequel::ValidationFailed, /jwks_uri/)
    end

    it "accepts public https jwks_uri" do
      expect { described_class.create(base.merge(jwks_uri: "https://auth.example.com/jwks")) }.not_to raise_error
    end

    it "rejects missing name" do
      expect { described_class.create(base.merge(jwks_uri: "https://auth.example.com/jwks", name: nil)) }
        .to raise_error(Sequel::ValidationFailed)
    end

    it "rejects invalid name" do
      expect { described_class.create(base.merge(jwks_uri: "https://auth.example.com/jwks", name: "Bad Name!")) }
        .to raise_error(Sequel::ValidationFailed, /name/)
    end

    it "rejects malformed jwks_uri" do
      expect { described_class.create(base.merge(jwks_uri: "https://exa mple.com/jwks")) }
        .to raise_error(Sequel::ValidationFailed, /jwks_uri/)
    end

    it "rejects missing jwks_uri" do
      expect { described_class.create(base.merge(jwks_uri: nil)) }
        .to raise_error(Sequel::ValidationFailed, /jwks_uri/)
    end

    it "rejects ipv6 literal jwks_uri" do
      expect { described_class.create(base.merge(jwks_uri: "https://[2001:db8::1]/jwks")) }
        .to raise_error(Sequel::ValidationFailed, /jwks_uri/)
    end

    it "rejects jwks_uri without a host" do
      expect { described_class.create(base.merge(jwks_uri: "https:///jwks")) }
        .to raise_error(Sequel::ValidationFailed, /jwks_uri/)
    end
  end

  it "is valid subject tag member for its project" do
    expect(SubjectTag.valid_member?(project.id, issuer)).to be(true)
  end

  it "is not valid subject tag member for another project" do
    other_project = Project.create(name: "other")
    expect(SubjectTag.valid_member?(other_project.id, issuer)).to be(false)
  end

  it "cleans up ACEs and tag memberships on destroy" do
    tag = SubjectTag.create(project_id: project.id, name: "test-tag")
    tag.add_member(issuer.id)
    AccessControlEntry.create(project_id: project.id, subject_id: issuer.id)

    expect(DB[:applied_subject_tag].where(subject_id: issuer.id).count).to eq(1)
    expect(AccessControlEntry.where(subject_id: issuer.id).count).to eq(1)

    issuer.destroy

    expect(DB[:applied_subject_tag].where(subject_id: issuer.id).count).to eq(0)
    expect(AccessControlEntry.where(subject_id: issuer.id).count).to eq(0)
  end

  it "is destroyed when its project is destroyed" do
    issuer
    expect { project.destroy }.not_to raise_error
    expect(described_class[issuer.id]).to be_nil
  end

  it "is destroyed when its account is destroyed" do
    issuer
    expect { account.destroy }.not_to raise_error
    expect(described_class[issuer.id]).to be_nil
  end
end
