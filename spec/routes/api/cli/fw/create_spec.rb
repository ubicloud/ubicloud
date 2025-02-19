# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli fw create" do
  it "creates firewall with no option" do
    expect(Firewall.count).to eq 0
    body = cli(%w[fw eu-central-h1/test-fw create])
    expect(Firewall.count).to eq 1
    fw = Firewall.first
    expect(fw.name).to eq "test-fw"
    expect(fw.description).to eq ""
    expect(body).to eq "Firewall created with id: #{fw.ubid}\n"
  end

  it "creates firewall with -d option" do
    expect(Firewall.count).to eq 0
    body = cli(%w[fw eu-central-h1/test-fw create -d test-description])
    expect(Firewall.count).to eq 1
    fw = Firewall.first
    expect(fw.name).to eq "test-fw"
    expect(fw.description).to eq "test-description"
    expect(body).to eq "Firewall created with id: #{fw.ubid}\n"
  end
end
