# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw attach-subnet" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
    fw = Firewall.first
    cli(%w[fw eu-central-h1/test-fw create])
    @fw = Firewall.exclude(id: fw.id).first
  end

  it "attaches firewall to subnet" do
    expect(@fw.private_subnets).to be_empty
    expect(cli(%W[fw eu-central-h1/test-fw attach-subnet #{@ps.ubid}])).to eq "Attached private subnet with id #{@ps.ubid} to firewall with id #{@fw.ubid}\n"
    expect(@fw.reload.private_subnets.map(&:ubid)).to eq [@ps.ubid]
  end
end
