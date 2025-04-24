# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb attach-vm" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    @vm = Vm.first
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
    cli(%W[lb eu-central-h1/test-lb create #{@ps.ubid} 12345 54321])
    cli(%W[lb eu-central-h1/test-lb attach-vm #{@vm.ubid}])
    @lb = LoadBalancer.first
  end

  it "detaches VM from load balancer" do
    expect(@lb.vm_ports_dataset.select_map(:state)).to eq ["down"]
    expect(cli(%W[lb eu-central-h1/test-lb detach-vm #{@vm.ubid}])).to eq "Detached VM with id #{@vm.ubid} from load balancer with id #{@lb.ubid}\n"
    expect(@lb.vm_ports_dataset.select_map(:state)).to eq ["detaching"]
  end
end
