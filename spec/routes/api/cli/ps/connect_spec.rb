# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli ps connect" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    cli(%w[ps eu-central-h1/test-ps2 create])
    @ps1, @ps2 = PrivateSubnet.all
  end

  it "connects requested private subnet to this subnet" do
    expect(ConnectedSubnet.count).to eq 0
    expect(cli(%W[ps eu-central-h1/#{@ps1.name} connect #{@ps2.ubid}])).to eq "Connected private subnets with ids #{@ps2.ubid} and #{@ps1.ubid}\n"
    expect(ConnectedSubnet.count).to eq 1
  end
end
