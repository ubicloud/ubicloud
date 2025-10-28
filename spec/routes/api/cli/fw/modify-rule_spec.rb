# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw modify-rule" do
  before do
    cli(%w[fw eu-central-h1/test-fw create])
    cli(%W[fw eu-central-h1/test-fw add-rule 1.2.3.0/24])
    @fwr = FirewallRule.first
  end

  it "can support all options" do
    body = cli(%W[fw eu-central-h1/test-fw modify-rule -c 1.2.4.0/24 -s 1 -e 2 -d my-desc #{@fwr.ubid}])
    expect(body).to eq "Modified firewall rule with id: #{@fwr.ubid}\n"
    @fwr.reload
    expect(@fwr.cidr.to_s).to eq "1.2.4.0/24"
    expect(@fwr.port_range.to_range).to eq(1...3)
    expect(@fwr.description).to eq "my-desc"
  end

  it "can modify cidr with -c" do
    body = cli(%W[fw eu-central-h1/test-fw modify-rule -c 1.2.4.0/24 #{@fwr.ubid}])
    expect(body).to eq "Modified firewall rule with id: #{@fwr.ubid}\n"
    @fwr.reload
    expect(@fwr.cidr.to_s).to eq "1.2.4.0/24"
    expect(@fwr.port_range.to_range).to eq(0...65536)
    expect(@fwr.description).to be_nil
  end

  it "can modify port range with -s" do
    body = cli(%W[fw eu-central-h1/test-fw modify-rule -s 1 #{@fwr.ubid}])
    expect(body).to eq "Modified firewall rule with id: #{@fwr.ubid}\n"
    @fwr.reload
    expect(@fwr.cidr.to_s).to eq "1.2.3.0/24"
    expect(@fwr.port_range.to_range).to eq(1...2)
    expect(@fwr.description).to be_nil
  end

  it "can modify port range with -e" do
    body = cli(%W[fw eu-central-h1/test-fw modify-rule -e 2 #{@fwr.ubid}])
    expect(body).to eq "Modified firewall rule with id: #{@fwr.ubid}\n"
    @fwr.reload
    expect(@fwr.cidr.to_s).to eq "1.2.3.0/24"
    expect(@fwr.port_range.to_range).to eq(0...3)
    expect(@fwr.description).to be_nil
  end

  it "can modify description with -d" do
    body = cli(%W[fw eu-central-h1/test-fw modify-rule -d my-desc #{@fwr.ubid}])
    expect(body).to eq "Modified firewall rule with id: #{@fwr.ubid}\n"
    @fwr.reload
    expect(@fwr.cidr.to_s).to eq "1.2.3.0/24"
    expect(@fwr.port_range.to_range).to eq(0...65536)
    expect(@fwr.description).to eq "my-desc"
  end
end
