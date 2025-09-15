# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli ps connect" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    cli(%w[ps eu-central-h1/test-ps2 create])
    @ps1, @ps2 = PrivateSubnet.order(:name).all
  end

  it "connects requested private subnet to this subnet by id" do
    expect(ConnectedSubnet.count).to eq 0
    expect(cli(%W[ps eu-central-h1/test-ps connect #{@ps2.ubid}])).to eq "Connected private subnet #{@ps2.ubid} to #{@ps1.ubid}\n"
    expect(ConnectedSubnet.count).to eq 1
  end

  it "connects requested private subnet to this subnet by name" do
    expect(ConnectedSubnet.count).to eq 0
    expect(cli(%W[ps eu-central-h1/test-ps connect test-ps2])).to eq "Connected private subnet test-ps2 to #{@ps1.ubid}\n"
    expect(ConnectedSubnet.count).to eq 1
  end

  it "errors if attempting to connect private subnet to itself" do
    expect(cli(%W[ps eu-central-h1/test-ps connect test-ps], status: 400)).to eq "! Unexpected response status: 400\nDetails: Cannot connect private subnet to itself\n"
    expect(ConnectedSubnet.count).to eq 0
  end
end
