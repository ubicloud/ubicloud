# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb create" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
  end

  it "creates load balancer with no option and private subnet by id" do
    expect(LoadBalancer.count).to eq 0
    body = cli(%W[lb eu-central-h1/test-lb create #{@ps.ubid} 12345 54321])
    expect(LoadBalancer.count).to eq 1
    lb = LoadBalancer.first
    expect(lb).to be_a LoadBalancer
    expect(lb.name).to eq "test-lb"
    expect(lb.private_subnet_id).to eq @ps.id
    expect(lb.ports.first.src_port).to eq 12345
    expect(lb.ports.first.dst_port).to eq 54321
    expect(lb.algorithm).to eq "round_robin"
    expect(lb.health_check_protocol).to eq "http"
    expect(lb.health_check_endpoint).to eq "/up"
    expect(lb.stack).to eq "dual"
    expect(body).to eq "Load balancer created with id: #{lb.ubid}\n"
  end

  it "creates load balancer with -aeps options and private subnet by name" do
    expect(LoadBalancer.count).to eq 0
    body = cli(%W[lb eu-central-h1/test-lb create -a hash_based -e /up2 -p https -s ipv4 test-ps 1234 5432])
    expect(LoadBalancer.count).to eq 1
    lb = LoadBalancer.first
    expect(lb).to be_a LoadBalancer
    expect(lb.name).to eq "test-lb"
    expect(lb.private_subnet_id).to eq @ps.id
    expect(lb.ports.first.src_port).to eq 1234
    expect(lb.ports.first.dst_port).to eq 5432
    expect(lb.algorithm).to eq "hash_based"
    expect(lb.health_check_protocol).to eq "https"
    expect(lb.health_check_endpoint).to eq "/up2"
    expect(lb.stack).to eq "ipv4"
    expect(body).to eq "Load balancer created with id: #{lb.ubid}\n"
  end
end
