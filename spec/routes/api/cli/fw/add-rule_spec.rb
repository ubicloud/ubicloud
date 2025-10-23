# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw add-rule" do
  before do
    cli(%w[fw eu-central-h1/test-fw create])
    @fw = Firewall.first
    @fw.firewall_rules_dataset.destroy
  end

  it "adds rule to firewall" do
    expect(FirewallRule.count).to eq 0
    body = cli(%W[fw eu-central-h1/test-fw add-rule 1.2.3.0/24])
    expect(FirewallRule.count).to eq 1
    fwr = FirewallRule.first
    expect(body).to eq "Added firewall rule with id: #{fwr.ubid}\n"
    expect(fwr.cidr.to_s).to eq "1.2.3.0/24"
    expect(fwr.port_range.to_range).to eq(0...65536)
    expect(fwr.description).to be_nil
    expect(fwr.firewall_id).to eq @fw.id
  end

  it "supports -d option to set description" do
    expect(FirewallRule.count).to eq 0
    body = cli(%W[fw eu-central-h1/test-fw add-rule -d fwrd 1.2.3.0/24])
    expect(FirewallRule.count).to eq 1
    fwr = FirewallRule.first
    expect(body).to eq "Added firewall rule with id: #{fwr.ubid}\n"
    expect(fwr.cidr.to_s).to eq "1.2.3.0/24"
    expect(fwr.port_range.to_range).to eq(0...65536)
    expect(fwr.description).to eq("fwrd")
    expect(fwr.firewall_id).to eq @fw.id
  end

  it "supports -s and -e options to set port range" do
    expect(FirewallRule.count).to eq 0
    body = cli(%W[fw eu-central-h1/test-fw add-rule -s 5432 -e 5440 1.2.0.0/16])
    expect(FirewallRule.count).to eq 1
    fwr = FirewallRule.first
    expect(body).to eq "Added firewall rule with id: #{fwr.ubid}\n"
    expect(fwr.cidr.to_s).to eq "1.2.0.0/16"
    expect(fwr.port_range.to_range).to eq(5432...5441)
    expect(fwr.description).to be_nil
    expect(fwr.firewall_id).to eq @fw.id
  end

  it "supports -s option to open single port" do
    expect(FirewallRule.count).to eq 0
    body = cli(%W[fw eu-central-h1/test-fw add-rule -s 5432 1.2.3.4/32])
    expect(FirewallRule.count).to eq 1
    fwr = FirewallRule.first
    expect(body).to eq "Added firewall rule with id: #{fwr.ubid}\n"
    expect(fwr.cidr.to_s).to eq "1.2.3.4/32"
    expect(fwr.port_range.to_range).to eq(5432...5433)
    expect(fwr.description).to be_nil
    expect(fwr.firewall_id).to eq @fw.id
  end
end
