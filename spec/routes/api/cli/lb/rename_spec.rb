# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb rename" do
  it "renames load balancer" do
    cli(%w[ps eu-central-h1/test-ps create])
    cli(%W[lb eu-central-h1/test-lb create #{PrivateSubnet.first.ubid} 12345 54321])
    lb = LoadBalancer.first
    expect(lb.semaphores_dataset.all).to eq []
    expect(cli(%w[lb eu-central-h1/test-lb rename new-name])).to eq "Load balancer renamed to new-name\n"
    expect(LoadBalancer.first.name).to eq "new-name"
    expect(lb.semaphores_dataset.select_order_map(:name)).to eq %w[refresh_cert rewrite_dns_records]
  end
end
