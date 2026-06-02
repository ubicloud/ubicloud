# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli jw show" do
  it "shows JWT issuer details" do
    ji = JwtIssuer.create(
      project_id: @project.id,
      account_id: @account.id,
      name: "test-issuer",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
      audience: "ubicloud",
    )

    expect(cli(%W[jw #{ji.ubid} show])).to eq <<~END
      id: #{ji.ubid}
      name: test-issuer
      issuer: https://auth.example.com
      jwks_uri: https://auth.example.com/.well-known/jwks.json
      audience: ubicloud
    END
  end
end
