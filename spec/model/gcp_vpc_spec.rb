# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GcpVpc do
  subject(:gcp_vpc) {
    described_class.create(
      project_id: project.id,
      location_id: location.id,
      name: "ubicloud-#{project.ubid}-#{location.ubid}",
    )
  }

  let(:project) { Project.create(name: "gcp-vpc-test") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }

  it "has associations" do
    Strand.create_with_id(gcp_vpc, prog: "Vnet::Gcp::VpcNexus", label: "start")

    expect(gcp_vpc.strand).to be_a(Strand)
    expect(gcp_vpc.project).to eq(project)
    expect(gcp_vpc.location).to eq(location)
  end

  it "has one_to_many private_subnets" do
    ps = PrivateSubnet.create(
      name: "ps", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "waiting",
    )
    DB[:private_subnet_gcp_vpc].insert(private_subnet_id: ps.id, gcp_vpc_id: gcp_vpc.id)

    expect(gcp_vpc.private_subnets.map(&:id)).to eq([ps.id])
  end

  it "has destroy semaphore" do
    Strand.create_with_id(gcp_vpc, prog: "Vnet::Gcp::VpcNexus", label: "start")
    gcp_vpc.incr_destroy
    expect(gcp_vpc.semaphores_dataset.select_map(:name)).to eq(["destroy"])
  end

  it "enforces unique project_id and location_id for shared rows" do
    gcp_vpc
    expect {
      described_class.create(
        project_id: project.id,
        location_id: location.id,
        name: "duplicate-vpc",
      )
    }.to raise_error(Sequel::ValidationFailed)
  end

  it "allows multiple dedicated rows in the same project+location" do
    ps1 = PrivateSubnet.create(
      name: "ps1", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "waiting",
    )
    ps2 = PrivateSubnet.create(
      name: "ps2", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbc::/64", net4: "10.0.1.0/26", state: "waiting",
    )

    described_class.create(
      project_id: project.id, location_id: location.id,
      name: "dedicated-vpc-1", dedicated_for_subnet_id: ps1.id,
    )
    expect {
      described_class.create(
        project_id: project.id, location_id: location.id,
        name: "dedicated-vpc-2", dedicated_for_subnet_id: ps2.id,
      )
    }.not_to raise_error
  end

  it "rejects two dedicated rows pointing to the same subnet" do
    ps = PrivateSubnet.create(
      name: "ps", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "waiting",
    )

    described_class.create(
      project_id: project.id, location_id: location.id,
      name: "dedicated-vpc-1", dedicated_for_subnet_id: ps.id,
    )
    expect {
      described_class.create(
        project_id: project.id, location_id: location.id,
        name: "dedicated-vpc-1-dup", dedicated_for_subnet_id: ps.id,
      )
    }.to raise_error(Sequel::ValidationFailed)
  end

  it "exposes dedicated_for_private_subnet association" do
    ps = PrivateSubnet.create(
      name: "ps", location_id: location.id, project_id: project.id,
      net6: "fd10:9b0b:6b4b:8fbb::/64", net4: "10.0.0.0/26", state: "waiting",
    )
    vpc = described_class.create(
      project_id: project.id, location_id: location.id,
      name: "dedicated-vpc", dedicated_for_subnet_id: ps.id,
    )

    expect(vpc.dedicated_for_private_subnet.id).to eq(ps.id)
    expect(gcp_vpc.dedicated_for_private_subnet).to be_nil
  end
end
