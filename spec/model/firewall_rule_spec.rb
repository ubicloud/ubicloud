# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe FirewallRule do
  describe "FirewallRule" do
    let(:fw) {
      Firewall.create_with_id(location: "hetzner-hel1")
    }

    it "returns ip6? properly" do
      fw_rule = described_class.create_with_id(cidr: "::/0", firewall_id: fw.id)
      expect(fw_rule.ip6?).to be true
      fw_rule.update(cidr: "0.0.0.0/0")
      expect(fw_rule.ip6?).to be false
    end
  end
end
