# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::PostgresServer do
  let(:project) { Project.create(name: "pg-server-test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:location) { Location[location_id] }
  let(:timeline) { create_postgres_timeline(location_id:) }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
    )
  }
  let(:pg) {
    pr = create_postgres_resource(project:, location_id:)
    pr.update(private_subnet_id: private_subnet.id)
    pr
  }

  def create_server(timeline_access: "push", is_representative: true, synchronization_status: "ready", strand_label: "wait")
    vm = create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}")
    server = PostgresServer.create(
      timeline:, resource_id: pg.id, vm_id: vm.id,
      is_representative:,
      synchronization_status:,
      timeline_access:,
      version: "17",
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: strand_label)
    server
  end

  it "serializes a primary server" do
    server = create_server(timeline_access: "push", is_representative: true)
    data = described_class.serialize(server)

    expect(data[:id]).to eq(server.ubid)
    expect(data[:role]).to eq("primary")
    expect(data[:state]).to eq("running")
    expect(data[:synchronization_status]).to eq("ready")
    expect(data).not_to have_key(:is_representative)
    expect(data[:vm]).to be_a(Hash)
    expect(data[:vm][:id]).to eq(server.vm.ubid)
  end

  it "serializes a standby server" do
    create_server(timeline_access: "push", is_representative: true)
    server = create_server(timeline_access: "fetch", is_representative: false, synchronization_status: "catching_up", strand_label: "wait_catch_up")
    data = described_class.serialize(server)

    expect(data[:role]).to eq("standby")
    expect(data[:state]).to eq("synchronizing")
    expect(data[:synchronization_status]).to eq("catching_up")
  end

  it "serializes a collection of servers" do
    primary = create_server(timeline_access: "push", is_representative: true)
    standby = create_server(timeline_access: "fetch", is_representative: false, synchronization_status: "ready")
    data = described_class.serialize([primary, standby])

    expect(data.length).to eq(2)
    expect(data[0][:role]).to eq("primary")
    expect(data[1][:role]).to eq("standby")
  end
end
