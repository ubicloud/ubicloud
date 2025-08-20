# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb update" do
  before do
    cli(%w[vm eu-central-h1/test-vm create] << "a a")
    cli(%w[vm eu-central-h1/test-vm2 create] << "b b")
    @vm1, @vm2 = Vm.all
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
    cli(%W[lb eu-central-h1/test-lb create #{@ps.ubid} 12345 54321])
    @lb = LoadBalancer.first
    @lb.add_vm(@vm1)
  end

  it "updates the load balancer" do
    expect(@lb.vms.map(&:ubid)).to eq [@vm1.ubid]
    expect(cli(%W[lb eu-central-h1/test-lb update hash_based 1234 5432 /up2 #{@vm1.ubid}])).to eq "Updated load balancer with id #{@lb.ubid}\n"
    @lb.reload
    expect(@lb.ports.first.src_port).to eq 1234
    expect(@lb.ports.first.dst_port).to eq 5432
    expect(@lb.algorithm).to eq "hash_based"
    expect(@lb.health_check_endpoint).to eq "/up2"
    expect(@lb.vms.map(&:ubid)).to eq [@vm1.ubid]
  end

  it "adds new VMs the load balancer by id" do
    expect(@lb.vms.map(&:ubid)).to eq [@vm1.ubid]
    expect(cli(%W[lb eu-central-h1/test-lb update hash_based 1234 5432 /up2 #{@vm1.ubid} #{@vm2.ubid}])).to eq "Updated load balancer with id #{@lb.ubid}\n"
    @lb.reload
    expect(@lb.ports.first.src_port).to eq 1234
    expect(@lb.ports.first.dst_port).to eq 5432
    expect(@lb.algorithm).to eq "hash_based"
    expect(@lb.health_check_endpoint).to eq "/up2"
    expect(@lb.vms.map(&:ubid).sort).to eq [@vm1.ubid, @vm2.ubid].sort
  end

  it "adds new VMs the load balancer by name" do
    expect(@lb.vms.map(&:ubid)).to eq [@vm1.ubid]
    expect(cli(%W[lb eu-central-h1/test-lb update hash_based 1234 5432 /up2 test-vm test-vm2])).to eq "Updated load balancer with id #{@lb.ubid}\n"
    @lb.reload
    expect(@lb.ports.first.src_port).to eq 1234
    expect(@lb.ports.first.dst_port).to eq 5432
    expect(@lb.algorithm).to eq "hash_based"
    expect(@lb.health_check_endpoint).to eq "/up2"
    expect(@lb.vms.map(&:ubid).sort).to eq [@vm1.ubid, @vm2.ubid].sort
  end

  it "removes VMs not given from the load balancer" do
    expect(@lb.vms.map(&:ubid)).to eq [@vm1.ubid]
    expect(cli(%W[lb eu-central-h1/test-lb update hash_based 1234 5432 /up2])).to eq "Updated load balancer with id #{@lb.ubid}\n"
    @lb.reload
    expect(@lb.ports.first.src_port).to eq 1234
    expect(@lb.ports.first.dst_port).to eq 5432
    expect(@lb.algorithm).to eq "hash_based"
    expect(@lb.health_check_endpoint).to eq "/up2"
    expect(@lb.vms).to be_empty
  end
end
