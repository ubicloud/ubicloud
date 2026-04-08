# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GcpVpc do
  subject(:gcp_vpc) {
    id = described_class.generate_uuid
    described_class.create_with_id(id,
      project_id: project.id,
      location_id: location.id,
      name: "ubicloud-#{project.ubid}-#{location.ubid}")
  }

  let(:project) { Project.create(name: "gcp-vpc-test") }
  let(:location) {
    Location.create(name: "gcp-us-central1", provider: "gcp",
      display_name: "GCP US Central 1", ui_name: "GCP US Central 1", visible: true)
  }

  it "has associations" do
    Strand.create(prog: "Vnet::Gcp::VpcNexus", label: "start") { it.id = gcp_vpc.id }

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
    Strand.create(prog: "Vnet::Gcp::VpcNexus", label: "start") { it.id = gcp_vpc.id }
    gcp_vpc.incr_destroy
    expect(gcp_vpc.semaphores_dataset.select_map(:name)).to eq(["destroy"])
  end

  it "enforces unique project_id and location_id" do
    gcp_vpc
    expect {
      described_class.create_with_id(described_class.generate_uuid,
        project_id: project.id,
        location_id: location.id,
        name: "duplicate-vpc")
    }.to raise_error(Sequel::ValidationFailed)
  end
end
