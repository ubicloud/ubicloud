# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb enable-ssl-certificate" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
    cli(%W[lb eu-central-h1/test-lb create #{@ps.ubid} 12345 54321])
    @lb = LoadBalancer.first
  end

  it "enables SSL certificates" do
    expect(cli(%W[lb eu-central-h1/test-lb enable-ssl-certificate])).to eq "Enabled SSL certificate for load balancer with id #{@lb.ubid}\n"
    expect(@lb.reload.cert_enabled).to be true
  end
end
