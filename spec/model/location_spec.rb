# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Location do
  subject(:p2_loc) { described_class.create(name: "l2", display_name: "l2", ui_name: "l2", visible: true, provider: "aws", project_id: p2_id) }

  let(:p1_id) { Project.create(name: "pj1").id }

  let(:p2_id) { Project.create(name: "pj2").id }

  let(:p1_loc) { described_class.create(name: "l1", display_name: "l1", ui_name: "l1", visible: true, provider: "aws", project_id: p1_id) }

  it ".for_project filters dataset to given project and non-project-specific locations" do
    p1_loc
    p2_loc
    expect(described_class.for_project(p1_id).select_order_map(:name)).to eq ["github-runners", "hetzner-ai", "hetzner-fsn1", "hetzner-hel1", "l1", "latitude-ai", "latitude-fra", "leaseweb-wdc02", "tr-ist-u1", "tr-ist-u1-tom", "us-east-1", "us-west-2"]
    expect(described_class.for_project(p2_id).select_order_map(:name)).to eq ["github-runners", "hetzner-ai", "hetzner-fsn1", "hetzner-hel1", "l2", "latitude-ai", "latitude-fra", "leaseweb-wdc02", "tr-ist-u1", "tr-ist-u1-tom", "us-east-1", "us-west-2"]
  end

  it ".visible_or_for_project filters dataset to given project and visible non-project-specific locations" do
    p1_loc
    p2_loc
    expect(described_class.visible_or_for_project(p1_id, []).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l1", "leaseweb-wdc02"]
    expect(described_class.visible_or_for_project(p2_id, []).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l2", "leaseweb-wdc02"]
    expect(described_class.visible_or_for_project(p1_id, []).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l1", "leaseweb-wdc02"]
    expect(described_class.visible_or_for_project(p1_id, ["latitude-ai"]).select_order_map(:name)).to eq ["hetzner-fsn1", "hetzner-hel1", "l1", "latitude-ai", "leaseweb-wdc02"]
  end

  it "#visible_or_for_project? returns whether the location is visible or related to the given project" do
    expect(p1_loc.visible_or_for_project?(p1_id, [])).to be true
    expect(p1_loc.visible_or_for_project?(p2_id, [])).to be false
    expect(p2_loc.visible_or_for_project?(p2_id, [])).to be true
    expect(p2_loc.visible_or_for_project?(p1_id, [])).to be false
    expect(described_class[name: "hetzner-fsn1"].visible_or_for_project?(p1_id, [])).to be true
    expect(described_class[name: "github-runners"].visible_or_for_project?(p1_id, [])).to be false
    expect(described_class[name: "latitude-ai"].visible_or_for_project?(p1_id, [])).to be false
    expect(described_class[name: "latitude-ai"].visible_or_for_project?(p1_id, ["latitude-ai"])).to be true
  end

  it "emits a log and returns [] for aws_azs if not aws location" do
    p1_loc.update(provider: "hetzner")
    expect { p1_loc.aws_azs }.to raise_error("azs is only valid for aws locations")
    expect(LocationAwsAz.count).to eq(0)
  end

  it "returns the aws azs for an aws location" do
    p1_loc.add_location_aws_az(az: "a", zone_id: "123")
    p1_loc.add_location_aws_az(az: "b", zone_id: "456")
    expect(p1_loc.aws_azs).to eq([LocationAwsAz[az: "a"], LocationAwsAz[az: "b"]])
  end

  it "fetches aws azs from aws if not present" do
    expect(p1_loc).to receive(:get_azs_from_aws).and_return([instance_double(Aws::EC2::Types::AvailabilityZone, zone_name: "l1a", zone_id: "123"), instance_double(Aws::EC2::Types::AvailabilityZone, zone_name: "l1b", zone_id: "456")])
    expect(p1_loc.aws_azs).to eq([LocationAwsAz[location_id: p1_loc.id, az: "a", zone_id: "123"], LocationAwsAz[location_id: p1_loc.id, az: "b", zone_id: "456"]])
    expect(LocationAwsAz.count).to eq(2)
  end
end
