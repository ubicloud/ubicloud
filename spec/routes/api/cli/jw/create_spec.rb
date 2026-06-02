# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli jw create" do
  it "creates a JWT issuer" do
    expect(JwtIssuer.count).to eq 0
    body = cli(%w[jw create my-issuer https://auth.example.com https://auth.example.com/.well-known/jwks.json])
    expect(JwtIssuer.count).to eq 1
    ji = JwtIssuer.first
    expect(ji.name).to eq "my-issuer"
    expect(ji.issuer).to eq "https://auth.example.com"
    expect(ji.jwks_uri).to eq "https://auth.example.com/.well-known/jwks.json"
    expect(ji.audience).to be_nil
    expect(body).to eq "JWT issuer created with id: #{ji.ubid}\n"
  end

  it "creates a JWT issuer with audience" do
    body = cli(%w[jw create -a ubicloud my-issuer https://auth.example.com https://auth.example.com/.well-known/jwks.json])
    ji = JwtIssuer.first
    expect(ji.audience).to eq "ubicloud"
    expect(body).to eq "JWT issuer created with id: #{ji.ubid}\n"
  end
end
