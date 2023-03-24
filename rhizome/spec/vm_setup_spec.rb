# frozen_string_literal: true

require_relative "../lib/vm_setup"

RSpec.describe VmSetup do
  subject(:vs) { described_class.new("test") }

  it "can halve an IPv6 network" do
    lower, upper = vs.subdivide_network(NetAddr.parse_net("2a01:4f9:2b:35b:7e40:e918::/95"))
    expect(lower.to_s).to eq("2a01:4f9:2b:35b:7e40:e918::/96")
    expect(upper.to_s).to eq("2a01:4f9:2b:35b:7e40:e919::/96")
  end

  it "templates user YAML" do
    vps = instance_spy(VmPath)
    expect(vs).to receive(:vp).and_return(vps).at_least(:once)
    vs.write_user_data("some_user", "some_ssh_key")
    expect(vps).to have_received(:write_user_data) {
      expect(_1).to match(/some_user/)
      expect(_1).to match(/some_ssh_key/)
    }
  end
end
