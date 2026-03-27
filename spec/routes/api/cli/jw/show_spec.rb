# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli jw show" do
  it "shows trusted JWT issuer details" do
    ji = TrustedJwtIssuer.create(
      project_id: @project.id,
      account_id: @account.id,
      name: "test-issuer",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
      audience: "ubicloud",
    )

    body = cli(%W[jw #{ji.ubid} show])
    expect(body).to include("id: #{ji.ubid}")
    expect(body).to include("name: test-issuer")
    expect(body).to include("issuer: https://auth.example.com")
    expect(body).to include("jwks_uri: https://auth.example.com/.well-known/jwks.json")
    expect(body).to include("audience: ubicloud")
  end
end
