# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe FirewallRule do
  describe "FirewallRule" do
    let(:ps) {
      PrivateSubnet.create_with_id(net6: "0::0", net4: "0.0.0.0/0", name: "x", location: "x")
    }

    it "returns ip6? properly" do
      fw_rule = described_class.create_with_id(ip: "::/0", private_subnet_id: ps.id)
      expect(fw_rule.ip6?).to be true
      fw_rule.update(ip: "0.0.0.0/0")
      expect(fw_rule.ip6?).to be false
    end
  end
end
