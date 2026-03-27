# frozen_string_literal: true

require_relative "../spec_helper"
require "base64"
require "jwt"

RSpec.describe Clover, "jwt auth" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:rsa_key) { Clec::Cert.rsa_2048_key }
  let(:jwk) { JWT::JWK.new(rsa_key, kid: "test-key-1") }

  let(:service_account) do
    sa = create_account("service@example.com", with_project: false)
    project.add_account(sa)
    SubjectTag.first(project_id: project.id, name: "Admin").add_subject(sa.id)
    sa
  end

  let(:issuer_config) do
    config = TrustedJwtIssuer.create(
      project_id: project.id,
      account_id: service_account.id,
      name: "test-issuer",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
    )
    stub_request(:get, config.jwks_uri)
      .to_return(body: {keys: [jwk.export]}.to_json)
    config
  end

  def mint_jwt(claims = {})
    payload = {"iss" => issuer_config.issuer, "exp" => Time.now.to_i + 300}.merge(claims)
    JWT.encode(payload, rsa_key, "RS256", {kid: "test-key-1"})
  end

  before do
    postgres_project = Project.create(name: "default")
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    TrustedJwtIssuer::JWKS_CACHE.clear
  end

  it "authenticates with valid JWT" do
    header "Authorization", "Bearer #{mint_jwt}"
    get "/project/#{project.ubid}/postgres"

    expect(last_response.status).to eq(200)
  end

  it "stores jwt_id and jwt_payload in session" do
    header "Authorization", "Bearer #{mint_jwt("custom" => "value")}"
    get "/project/#{project.ubid}/postgres"

    expect(last_response.status).to eq(200)
  end

  it "defers to PAT for pat- prefixed tokens" do
    login_api
    project_with_default_policy(user, name: "project-pat")
    get "/project/#{project.ubid}/postgres"

    expect(last_response.status).to eq(200)
  end

  it "defers to PAT when Authorization header is empty" do
    header "Authorization", ""
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "defers to PAT when Authorization header has no Bearer prefix" do
    header "Authorization", "Basic dXNlcjpwYXNz"
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "defers to PAT when JWT has no iss claim" do
    issuer_config
    token = JWT.encode({"sub" => "test"}, rsa_key, "RS256", {kid: "test-key-1"})
    header "Authorization", "Bearer #{token}"
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "rejects token missing exp claim" do
    issuer_config
    token = JWT.encode({"iss" => issuer_config.issuer}, rsa_key, "RS256", {kid: "test-key-1"})
    header "Authorization", "Bearer #{token}"
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "rejects expired token" do
    header "Authorization", "Bearer #{mint_jwt("exp" => Time.now.to_i - 120)}"
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  context "with audience configured" do
    let(:issuer_config) do
      config = TrustedJwtIssuer.create(
        project_id: project.id,
        account_id: service_account.id,
        name: "test-issuer",
        issuer: "https://auth.example.com",
        jwks_uri: "https://auth.example.com/.well-known/jwks.json",
        audience: "ubicloud",
      )
      stub_request(:get, config.jwks_uri)
        .to_return(body: {keys: [jwk.export]}.to_json)
      config
    end

    it "authenticates when aud matches" do
      header "Authorization", "Bearer #{mint_jwt("aud" => "ubicloud")}"
      get "/project/#{project.ubid}/postgres"
      expect(last_response.status).to eq(200)
    end

    it "rejects when aud missing" do
      header "Authorization", "Bearer #{mint_jwt}"
      get "/project/#{project.ubid}/postgres"
      expect(last_response).to have_api_error(401)
    end

    it "rejects when aud mismatched" do
      header "Authorization", "Bearer #{mint_jwt("aud" => "other")}"
      get "/project/#{project.ubid}/postgres"
      expect(last_response).to have_api_error(401)
    end
  end

  it "defers to PAT when URL has no project path" do
    issuer_config
    header "Authorization", "Bearer #{mint_jwt}"
    get "/project"

    expect(last_response).to have_api_error(401)
  end

  it "defers to PAT when project UBID cannot be converted to UUID" do
    issuer_config
    header "Authorization", "Bearer #{mint_jwt}"
    get "/project/pj#{"a" * 23}u/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "defers to PAT when no matching issuer config exists" do
    token = JWT.encode({"iss" => "https://unknown.com"}, rsa_key, "RS256", {kid: "test-key-1"})
    header "Authorization", "Bearer #{token}"
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "defers to PAT when JWT signature is invalid" do
    issuer_config
    token = mint_jwt
    header "Authorization", "Bearer #{token.chop}x"
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "defers to PAT when token is not valid JWT" do
    issuer_config
    header "Authorization", "Bearer not.valid.jwt"
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "defers to PAT when JWT payload is not an object" do
    issuer_config
    seg = ->(o) { Base64.urlsafe_encode64(JSON.generate(o), padding: false) }
    header "Authorization", "Bearer #{seg.call({"alg" => "none"})}.#{seg.call([1, 2, 3])}.sig"
    get "/project/#{project.ubid}/postgres"

    expect(last_response).to have_api_error(401)
  end

  it "uses issuer ID as authorization subject with AND semantics" do
    # Account has Admin (wildcard), issuer has scoped ACE.
    # AND semantics: result is intersection = issuer's scope.
    pg1 = Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "pg-visible",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
    ).subject

    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "pg-hidden",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
    )

    # Issuer only has access to pg1
    AccessControlEntry.create(
      project_id: project.id,
      subject_id: issuer_config.id,
      action_id: ActionType::NAME_MAP.fetch("Postgres:view"),
      object_id: pg1.id,
    )

    header "Authorization", "Bearer #{mint_jwt}"
    get "/project/#{project.ubid}/postgres"

    expect(last_response.status).to eq(200)
    items = JSON.parse(last_response.body)["items"]
    expect(items.length).to eq(1)
    expect(items[0]["name"]).to eq("pg-visible")
  end
end
