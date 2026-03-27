# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli jw create" do
  it "creates a trusted JWT issuer" do
    expect(TrustedJwtIssuer.count).to eq 0
    body = cli(%w[jw create -n my-issuer -i https://auth.example.com -j https://auth.example.com/.well-known/jwks.json])
    expect(TrustedJwtIssuer.count).to eq 1
    ji = TrustedJwtIssuer.first
    expect(ji.name).to eq "my-issuer"
    expect(ji.issuer).to eq "https://auth.example.com"
    expect(ji.jwks_uri).to eq "https://auth.example.com/.well-known/jwks.json"
    expect(ji.audience).to be_nil
    expect(body).to eq "Trusted JWT issuer created with id: #{ji.ubid}\n"
  end

  it "creates a trusted JWT issuer with audience" do
    cli(%w[jw create -n my-issuer -i https://auth.example.com -j https://auth.example.com/.well-known/jwks.json -a ubicloud])
    expect(TrustedJwtIssuer.first.audience).to eq "ubicloud"
  end
end
