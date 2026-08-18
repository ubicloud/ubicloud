# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli jw destroy" do
  before do
    cli(%w[jw create my-issuer https://auth.example.com https://auth.example.com/.well-known/jwks.json])
    @ji = JwtIssuer.first
  end

  it "destroys with -f flag" do
    expect(cli(%W[jw #{@ji.ubid} destroy -f])).to eq "JWT issuer has been removed\n"
    expect(@ji).not_to be_exist
  end

  it "asks for confirmation without -f" do
    expect(cli(%W[jw #{@ji.ubid} destroy], confirm_prompt: "Confirmation")).to eq <<~END
      Destroying this JWT issuer is not recoverable.
      Enter the name of the JWT issuer to confirm: #{@ji.name}
    END
    expect(@ji).to be_exist
  end

  it "destroys on correct confirmation" do
    expect(cli(%W[--confirm my-issuer jw #{@ji.ubid} destroy])).to eq "JWT issuer has been removed\n"
    expect(@ji).not_to be_exist
  end

  it "fails on incorrect confirmation" do
    expect(cli(%W[--confirm wrong jw #{@ji.ubid} destroy], status: 400)).to eq "! Confirmation of JWT issuer name not successful.\n"
    expect(@ji).to be_exist
  end
end
