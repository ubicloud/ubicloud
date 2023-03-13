# frozen_string_literal: true

require_relative "../lib/vm_setup"

RSpec.describe VmSetup do
  subject(:vs) { described_class.new("test") }

  it "can halve an IPv6 network" do
    lower, upper = vs.subdivide_network(NetAddr.parse_net("2a01:4f9:2b:35b:7e40:e918::/95"))
    expect(lower.to_s).to eq("2a01:4f9:2b:35b:7e40:e918::/96")
    expect(upper.to_s).to eq("2a01:4f9:2b:35b:7e40:e919::/96")
  end
end
