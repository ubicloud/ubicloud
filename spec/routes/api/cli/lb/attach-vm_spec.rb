# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb attach-vm" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
    cli(%W[lb eu-central-h1/test-lb create #{@ps.ubid} 12345 54321])
    @lb = LoadBalancer.first
  end

  it "attaches VM to load balancer" do
    expect(@lb.vms).to be_empty
    expect(cli(%W[lb eu-central-h1/test-lb attach-vm #{@vm.ubid}])).to eq "Attached VM with id #{@vm.ubid} to load balancer with id #{@lb.ubid}\n"
    expect(@lb.reload.vms.map(&:ubid)).to eq [@vm.ubid]
  end
end
