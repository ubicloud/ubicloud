# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli lb certificate" do
  it "returns active certificate for load balancer" do
    cli(%w[ps eu-central-h1/test-ps create])
    cli(%W[lb eu-central-h1/test-lb create #{PrivateSubnet.first.ubid} 12345 54321])
    expect(cli(%w[lb eu-central-h1/test-lb certificate], status: 404)).to eq "! Unexpected response status: 404\nDetails: Sorry, we couldn’t find the resource you’re looking for.\n"
    LoadBalancer.first.add_cert(hostname: "foo.ubicloud.com", cert: "EXAMPLE-CERT")
    expect(cli(%w[lb eu-central-h1/test-lb certificate])).to eq "EXAMPLE-CERT\n"
  end
end
