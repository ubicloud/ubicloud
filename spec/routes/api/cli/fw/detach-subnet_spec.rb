# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw attach-subnet" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
    @fw = Firewall.first
  end

  it "detaches firewall from subnet" do
    expect(@fw.private_subnets.map(&:ubid)).to eq [@ps.ubid]
    expect(cli(%W[fw eu-central-h1/#{@fw.name} detach-subnet #{@ps.ubid}])).to eq "Detached private subnet with id #{@ps.ubid} from firewall with id #{@fw.ubid}\n"
    expect(@fw.reload.private_subnets).to be_empty
  end
end
