# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "jwt issuer api" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }

  before do
    login_api
  end

  it "lists jwt issuers" do
    ji = TrustedJwtIssuer.create(
      project_id: project.id,
      account_id: user.id,
      name: "test",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
      audience: "ubicloud",
    )

    get "/project/#{project.ubid}/token/jwt-issuer"

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["items"].length).to eq(1)
    expect(body["items"][0]["id"]).to eq(ji.ubid)
    expect(body["items"][0]["name"]).to eq("test")
    expect(body["items"][0]["issuer"]).to eq("https://auth.example.com")
    expect(body["items"][0]["jwks_uri"]).to eq("https://auth.example.com/.well-known/jwks.json")
    expect(body["items"][0]["audience"]).to eq("ubicloud")
  end

  it "lists empty when no issuers" do
    get "/project/#{project.ubid}/token/jwt-issuer"

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["items"]).to eq([])
  end

  it "creates a jwt issuer" do
    post "/project/#{project.ubid}/token/jwt-issuer",
      {name: "new-issuer", issuer: "https://new.example.com", jwks_uri: "https://new.example.com/.well-known/jwks.json"}.to_json

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["name"]).to eq("new-issuer")
    expect(body["issuer"]).to eq("https://new.example.com")
    expect(body["audience"]).to be_nil
    expect(TrustedJwtIssuer.count).to eq(1)
  end

  it "creates a jwt issuer with audience" do
    post "/project/#{project.ubid}/token/jwt-issuer",
      {name: "new-issuer", issuer: "https://new.example.com", jwks_uri: "https://new.example.com/.well-known/jwks.json", audience: "ubicloud"}.to_json

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["audience"]).to eq("ubicloud")
    expect(TrustedJwtIssuer.first.audience).to eq("ubicloud")
  end

  it "rejects insecure jwks_uri" do
    post "/project/#{project.ubid}/token/jwt-issuer",
      {name: "bad", issuer: "https://new.example.com", jwks_uri: "http://new.example.com/.well-known/jwks.json"}.to_json

    expect(last_response.status).to eq(400)
  end

  it "gets a jwt issuer" do
    ji = TrustedJwtIssuer.create(
      project_id: project.id,
      account_id: user.id,
      name: "test",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
    )

    get "/project/#{project.ubid}/token/jwt-issuer/#{ji.ubid}"

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["id"]).to eq(ji.ubid)
  end

  it "returns 404 for nonexistent jwt issuer" do
    get "/project/#{project.ubid}/token/jwt-issuer/jw#{"a" * 24}"

    expect(last_response.status).to eq(404)
  end

  it "deletes a jwt issuer" do
    ji = TrustedJwtIssuer.create(
      project_id: project.id,
      account_id: user.id,
      name: "to-delete",
      issuer: "https://delete.example.com",
      jwks_uri: "https://delete.example.com/.well-known/jwks.json",
    )

    delete "/project/#{project.ubid}/token/jwt-issuer/#{ji.ubid}"

    expect(last_response.status).to eq(204)
    expect(TrustedJwtIssuer.count).to eq(0)
  end

  it "returns 404 when deleting nonexistent jwt issuer" do
    delete "/project/#{project.ubid}/token/jwt-issuer/jw#{"a" * 24}"

    expect(last_response.status).to eq(204)
  end
end
