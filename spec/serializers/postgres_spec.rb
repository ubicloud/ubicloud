# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Serializers::Postgres do
  let(:project) { Project.create(name: "pg-test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:location) { Location[location_id] }
  let(:timeline) { create_postgres_timeline(location_id:) }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"
    )
  }
  let(:time) {
    t = Time.now
    expect(Time).to receive(:now).and_return(t).at_least(:once)
    t
  }

  let(:pg) {
    pr = create_postgres_resource(project:, location_id:)
    pr.update(private_subnet_id: private_subnet.id)
    pr
  }

  def create_representative_server(primary: true)
    vm = create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}")
    server = PostgresServer.create(
      timeline:, resource_id: pg.id, vm_id: vm.id,
      is_representative: true,
      synchronization_status: "ready",
      timeline_access: primary ? "push" : "fetch",
      version: "17"
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
    server
  end

  it "can serialize when no earliest restore time (but latest is always present)" do
    time
    create_representative_server(primary: true)
    data = described_class.serialize(pg, {detailed: true})
    expect(data.fetch(:earliest_restore_time)).to be_nil
    expect(data.fetch(:latest_restore_time)).to eq(time.utc.iso8601)
  end

  it "can serialize when earliest_restore_time calculation raises an exception" do
    time
    create_representative_server(primary: true)
    expect(pg.timeline).to receive(:earliest_restore_time).and_raise("error")
    data = described_class.serialize(pg, {detailed: true})
    expect(data).not_to have_key(:earliest_restore_time)
    expect(data.fetch(:latest_restore_time)).to eq(time.utc.iso8601)
  end

  it "can serialize when have earliest/latest restore times" do
    time
    create_representative_server(primary: true)
    pg.timeline.update(cached_earliest_backup_at: time)
    pg.reload
    data = described_class.serialize(pg, {detailed: true})
    expect(data.fetch(:earliest_restore_time)).to eq((time + 5 * 60).utc.iso8601)
    expect(data.fetch(:latest_restore_time)).to eq(time.utc.iso8601)
  end

  it "can serialize when not primary" do
    create_representative_server(primary: false)
    data = described_class.serialize(pg, {detailed: true})
    expect(data).not_to have_key(:earliest_restore_time)
    expect(data).not_to have_key(:latest_restore_time)
  end

  it "includes created_at in detailed serialization" do
    create_representative_server(primary: true)
    data = described_class.serialize(pg)
    expect(data).to have_key(:created_at)
    expect(data[:created_at]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[Z+-]/)
  end
end
