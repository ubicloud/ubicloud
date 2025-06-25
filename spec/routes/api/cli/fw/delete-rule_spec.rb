# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw add-rule" do
  before do
    cli(%w[fw eu-central-h1/test-fw create])
    @fw = Firewall.first
    @fw.firewall_rules_dataset.destroy
    cli(%w[fw eu-central-h1/test-fw add-rule 1.2.3.0/24])
    @fwr = FirewallRule.first
  end

  it "deletes rule from firewall" do
    2.times do
      expect(cli(%W[fw eu-central-h1/test-fw delete-rule #{@fwr.ubid}])).to eq "Firewall rule, if it existed, has been deleted\n"
      expect(FirewallRule.count).to eq 0
    end
  end

  it "errors for invalid rule id format" do
    expect(cli(%W[fw eu-central-h1/test-fw delete-rule #{@fwr.ubid}/], status: 400)).to start_with "! Invalid rule id format\n"
    expect(FirewallRule.count).to eq 1
  end
end
