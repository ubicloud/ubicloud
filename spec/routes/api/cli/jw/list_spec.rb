# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli jw list" do
  it "lists trusted JWT issuers" do
    ji = TrustedJwtIssuer.create(
      project_id: @project.id,
      account_id: @account.id,
      name: "test-issuer",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
    )

    body = cli(%w[jw list])
    expect(body).to include(ji.ubid)
    expect(body).to include("test-issuer")
    expect(body).to include("https://auth.example.com")
  end

  it "lists with no headers" do
    TrustedJwtIssuer.create(
      project_id: @project.id,
      account_id: @account.id,
      name: "test",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
    )

    body = cli(%w[jw list -N])
    expect(body).not_to include("id")
    expect(body).to include("test")
  end
end
