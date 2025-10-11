# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb disable-ssl-certificate" do
  before do
    cli(%w[ps eu-central-h1/test-ps create])
    @ps = PrivateSubnet.first
    cli(%W[lb eu-central-h1/test-lb create #{@ps.ubid} 12345 54321])
    @lb = LoadBalancer.first
  end

  it "disables SSL certificates" do
    @lb.update(cert_enabled: true)
    expect(cli(%W[lb eu-central-h1/test-lb disable-ssl-certificate])).to eq "Disabled SSL certificate for load balancer with id #{@lb.ubid}\n"
    expect(@lb.reload.cert_enabled).to be false
  end
end
