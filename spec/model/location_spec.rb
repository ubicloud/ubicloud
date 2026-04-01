# frozen_string_literal: true

require_relative "spec_helper"
require "aws-sdk-ec2"

RSpec.describe Location do
  subject(:p2_loc) { described_class.create(name: "l2", display_name: "l2", ui_name: "l2", visible: true, provider: "aws", project_id: p2_id) }

  let(:p1_id) { Project.create(name: "pj1").id }

  let(:p2_id) { Project.create(name: "pj2").id }

  let(:p1_loc) { described_class.create(name: "l1", display_name: "l1", ui_name: "l1", visible: true, provider: "aws", project_id: p1_id) }

  it ".for_project filters dataset to given project and non-project-specific locations" do
    p1_loc
    p2_loc
    expect(described_class.for_project(p1_id).select_order_map(:name)).to eq ["gcp-us-central1", "github-runners", "hetzner-ai", "hetzner-fsn1", "hetzner-hel1", "l1", "latitude-ai", "latitude-fra", "leaseweb-wdc02", "tr-ist-u1", "tr-ist-u1-tom", "us-east-1", "us-west-2"]
    expect(described_class.for_project(p2_id).select_order_map(:name)).to eq ["gcp-us-central1", "github-runners", "hetzner-ai", "hetzner-fsn1", "hetzner-hel1", "l2", "latitude-ai", "latitude-fra", "leaseweb-wdc02", "tr-ist-u1", "tr-ist-u1-tom", "us-east-1", "us-west-2"]
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

  it "#provider_dispatcher_group_name returns the provider dispatch name" do
    expect(p2_loc.provider_dispatcher_group_name).to eq("aws")
    p2_loc.update(provider: "hetzner")
    expect(p2_loc.provider_dispatcher_group_name).to eq("metal")
  end

  it "#azs raises if not aws location" do
    p1_loc.update(provider: "hetzner")
    expect { p1_loc.azs }.to raise_error("azs is only valid for aws locations")
    expect(LocationAz.count).to eq(0)
  end

  it "#azs returns cached gcp azs" do
    gcp_loc = described_class.create(name: "gcp-azs-test", display_name: "gcp-azs-test", ui_name: "gcp-azs-test", visible: false, provider: "gcp")
    gcp_loc.add_location_az(az: "a")
    expect(gcp_loc.azs.map(&:az)).to eq(["a"])
  end

  it "returns the aws azs for an aws location" do
    p1_loc.add_location_az(az: "a", zone_id: "123")
    p1_loc.add_location_az(az: "b", zone_id: "456")
    expect(p1_loc.azs).to eq([LocationAz[az: "a"], LocationAz[az: "b"]])
  end

  it "fetches aws azs from aws if not present" do
    expect(p1_loc).to receive(:get_azs_from_aws).and_return([instance_double(Aws::EC2::Types::AvailabilityZone, zone_name: "l1a", zone_id: "123"), instance_double(Aws::EC2::Types::AvailabilityZone, zone_name: "l1b", zone_id: "456")])
    expect(p1_loc.azs).to eq([LocationAz[location_id: p1_loc.id, az: "a", zone_id: "123"], LocationAz[location_id: p1_loc.id, az: "b", zone_id: "456"]])
    expect(LocationAz.count).to eq(2)
  end

  it "raises descriptive error when AMI not found" do
    expect {
      p2_loc.pg_ami("16", "x64")
    }.to raise_error("No AMI found for PostgreSQL 16 (x64) in l2")
  end

  it "#pg_gce_image returns image path using image's hosting project" do
    PgGceImage.dataset.destroy
    gcp_loc = described_class.create(name: "gcp-image-test", display_name: "gcp-image-test", ui_name: "gcp-image-test", visible: false, provider: "gcp")
    PgGceImage.create_with_id(PgGceImage.generate_uuid, gcp_project_id: "image-hosting-project", gce_image_name: "postgres-ubuntu-2204-x64-20260218", arch: "x64")
    expect(gcp_loc.pg_gce_image("x64")).to eq("projects/image-hosting-project/global/images/postgres-ubuntu-2204-x64-20260218")
  end

  it "#pg_gce_image raises when no image found" do
    PgGceImage.dataset.destroy
    gcp_loc = described_class.create(name: "gcp-image-err", display_name: "gcp-image-err", ui_name: "gcp-image-err", visible: false, provider: "gcp")
    expect {
      gcp_loc.pg_gce_image("x64")
    }.to raise_error("No GCE image found for arch x64")
  end
end
