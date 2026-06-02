# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli jw list" do
  it "lists JWT issuers with headers by default" do
    ji = JwtIssuer.create(
      project_id: @project.id,
      account_id: @account.id,
      name: "test-issuer",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
    )

    expect(cli(%w[jw list])).to eq <<~END
      id#{" " * 24}  name#{" " * 7}  issuer#{" " * 18}  audience  jwks-uri#{" " * 38}
      #{ji.ubid}  test-issuer  https://auth.example.com  #{" " * 8}  https://auth.example.com/.well-known/jwks.json
    END
  end

  it "lists without headers when -N is given" do
    ji = JwtIssuer.create(
      project_id: @project.id,
      account_id: @account.id,
      name: "test",
      issuer: "https://auth.example.com",
      jwks_uri: "https://auth.example.com/.well-known/jwks.json",
    )

    expect(cli(%w[jw list -N])).to eq <<~END
      #{ji.ubid}  test  https://auth.example.com  #{" " * 0}  https://auth.example.com/.well-known/jwks.json
    END
  end
end
