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

  it ".postgres_locations includes metal, AWS, and GCP locations" do
    locations = described_class.postgres_locations
    names = locations.map(&:name)

    expect(names).to include("hetzner-fsn1", "leaseweb-wdc02")
    expect(names).to include("us-east-1", "us-west-2")
    expect(names).to include("gcp-us-central1")
    expect(names).not_to include("github-runners")
  end

  it ".postgres_locations excludes project-specific locations" do
    described_class.create(name: "my-aws", display_name: "my-aws", ui_name: "my-aws", visible: true, provider: "aws", project_id: p1_id)
    described_class.create(name: "my-gcp", display_name: "my-gcp", ui_name: "my-gcp", visible: true, provider: "gcp", project_id: p1_id)

    locations = described_class.postgres_locations
    names = locations.map(&:name)

    expect(names).not_to include("my-aws")
    expect(names).not_to include("my-gcp")
  end

  it "#azs raises if not aws location" do
    p1_loc.update(provider: "hetzner")
    expect { p1_loc.azs }.to raise_error("azs is only valid for aws locations")
    expect(LocationAwsAz.count).to eq(0)
  end

  it "#azs raises for gcp location" do
    gcp_loc = described_class.create(name: "gcp-azs-test", display_name: "gcp-azs-test", ui_name: "gcp-azs-test", visible: false, provider: "gcp")
    expect { gcp_loc.azs }.to raise_error("azs is only valid for aws locations")
  end

  it "returns the aws azs for an aws location" do
    p1_loc.add_location_aws_az(az: "a", zone_id: "123")
    p1_loc.add_location_aws_az(az: "b", zone_id: "456")
    expect(p1_loc.azs).to eq([LocationAwsAz[az: "a"], LocationAwsAz[az: "b"]])
  end

  it "fetches aws azs from aws if not present" do
    expect(p1_loc).to receive(:get_azs_from_aws).and_return([instance_double(Aws::EC2::Types::AvailabilityZone, zone_name: "l1a", zone_id: "123"), instance_double(Aws::EC2::Types::AvailabilityZone, zone_name: "l1b", zone_id: "456")])
    expect(p1_loc.azs).to eq([LocationAwsAz[location_id: p1_loc.id, az: "a", zone_id: "123"], LocationAwsAz[location_id: p1_loc.id, az: "b", zone_id: "456"]])
    expect(LocationAwsAz.count).to eq(2)
  end

  it "raises descriptive error when AMI not found" do
    expect {
      p2_loc.pg_ami("16", "x64")
    }.to raise_error("No AMI found for PostgreSQL 16 (x64) in l2")
  end

  it "#pg_gce_image returns image path from pg_gce_image table" do
    gcp_loc = described_class.create(name: "gcp-image-test", display_name: "gcp-image-test", ui_name: "gcp-image-test", visible: false, provider: "gcp")
    LocationCredential.create_with_id(gcp_loc,
      project_id: "my-gcp-project",
      service_account_email: "test@my-gcp-project.iam.gserviceaccount.com",
      credentials_json: "{}")
    PgGceImage.create_with_id(PgGceImage.generate_uuid, gcp_project_id: "my-gcp-project", gce_image_name: "postgres-ubuntu-2204-x64-20260218", pg_version: "16", arch: "x64")
    expect(gcp_loc.pg_gce_image("16", "x64")).to eq("projects/my-gcp-project/global/images/postgres-ubuntu-2204-x64-20260218")
  end

  it "#pg_gce_image raises when no image found" do
    gcp_loc = described_class.create(name: "gcp-image-err", display_name: "gcp-image-err", ui_name: "gcp-image-err", visible: false, provider: "gcp")
    LocationCredential.create_with_id(gcp_loc,
      project_id: "my-gcp-project-2",
      service_account_email: "test@my-gcp-project-2.iam.gserviceaccount.com",
      credentials_json: "{}")
    expect {
      gcp_loc.pg_gce_image("16", "x64")
    }.to raise_error("No GCE image found for PostgreSQL 16 (x64) in project my-gcp-project-2")
  end
end
