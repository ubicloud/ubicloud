# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli jw destroy" do
  before do
    cli(%w[jw create -n my-issuer -i https://auth.example.com -j https://auth.example.com/.well-known/jwks.json])
    @ji = TrustedJwtIssuer.first
  end

  it "destroys with -f flag" do
    expect(cli(%W[jw #{@ji.ubid} destroy -f])).to eq "Trusted JWT issuer has been removed\n"
    expect(@ji).not_to be_exist
  end

  it "asks for confirmation without -f" do
    expect(cli(%W[jw #{@ji.ubid} destroy], confirm_prompt: "Confirmation")).to include("Destroying this trusted JWT issuer")
    expect(@ji).to be_exist
  end

  it "destroys on correct confirmation" do
    expect(cli(%W[--confirm my-issuer jw #{@ji.ubid} destroy])).to eq "Trusted JWT issuer has been removed\n"
    expect(@ji).not_to be_exist
  end

  it "fails on incorrect confirmation" do
    expect(cli(%W[--confirm wrong jw #{@ji.ubid} destroy], status: 400)).to include("Confirmation of trusted JWT issuer name not successful")
    expect(@ji).to be_exist
  end
end
