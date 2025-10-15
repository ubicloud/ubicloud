# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "ips-v4" do
  before do
    hosts = (1..2).map do
      create_vm_host
    end

    %w[
      10.1.1.0/30
      10.1.2.0/31
      3.1.1.0/30
      5.1.1.0/32
    ].each do |cidr|
      Address.create(cidr: cidr, routed_to_host_id: hosts.sample.id)
    end

    addresses = Util.calculate_ips_v4

    allow(described_class).to receive(:ips_v4).and_return(addresses)
  end

  it "Returns the proper list of IP ranges" do
    expect(Util).not_to receive(:calculate_ips_v4)

    get "/ips-v4"
    expect(last_response.body).to eq "3.1.0.0/16\n10.1.0.0/16"
  end
end
