# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli ps create" do
  it "creates ps with no option" do
    expect(PrivateSubnet.count).to eq 0
    expect(Firewall.count).to eq 0
    body = cli(%w[ps eu-central-h1/test-ps create])
    expect(PrivateSubnet.count).to eq 1
    expect(Firewall.count).to eq 1
    ps = PrivateSubnet.first
    expect(ps).to be_a PrivateSubnet
    expect(ps.name).to eq "test-ps"
    expect(ps.display_location).to eq "eu-central-h1"
    expect(ps.firewalls).to eq Firewall.all
    expect(body).to eq "Private subnet created with id: #{ps.ubid}\n"
  end

  it "creates ps with -f option" do
    fw = Firewall.create(project_id: @project.id, location_id: "1f214853-0bc4-8020-b910-dffb867ef44f")
    Firewall.create(project_id: @project.id, location_id: "1f214853-0bc4-8020-b910-dffb867ef44f", name: "test-fw")
    body = cli(%W[ps eu-north-h1/test-ps2 create -f #{fw.ubid}])
    expect(PrivateSubnet.count).to eq 1
    ps = PrivateSubnet.first
    expect(ps.name).to eq "test-ps2"
    expect(ps.display_location).to eq "eu-north-h1"
    expect(ps.firewalls).to eq [fw]
    expect(body).to eq "Private subnet created with id: #{ps.ubid}\n"
  end
end
