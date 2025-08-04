# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe FirewallRule do
  let(:fw) {
    Firewall.create(location_id: Location::HETZNER_FSN1_ID, project_id: Project.create(name: "test").id)
  }

  it "returns ip6? properly" do
    fw_rule = described_class.create(cidr: "::/0", firewall_id: fw.id)
    expect(fw_rule.ip6?).to be true
    fw_rule.update(cidr: "0.0.0.0/0")
    expect(fw_rule.ip6?).to be false
  end
end
