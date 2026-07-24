# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresServerExtension do
  let(:project) { Project.create(name: "pg-ext-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:location) { Location[location_id] }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-ext-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
    )
  }

  let(:timeline) { create_postgres_timeline(location_id:) }

  def make_server(resource, name, representative: true)
    vm = create_hosted_vm(project, private_subnet, name)
    PostgresServer.create(
      timeline:, resource:, vm_id: vm.id, is_representative: representative,
      synchronization_status: "ready", timeline_access: representative ? "push" : "fetch", version: "17",
    )
  end

  it "belongs to a postgres server and carries the px UBID prefix" do
    server = make_server(create_postgres_resource(project:, location_id:), "pg-ext-vm")
    ext = described_class.create(postgres_server_id: server.id, name: "pgvector", state: "install_pending")

    expect(ext.postgres_server.id).to eq server.id
    expect(server.extensions.map(&:id)).to eq [ext.id]
    expect(ext.ubid).to start_with "px"
  end

  describe "state CHECK constraint" do
    it "rejects unknown states" do
      server = make_server(create_postgres_resource(project:, location_id:), "pg-state-vm")
      expect {
        DB.transaction(savepoint: true) do
          described_class.create(postgres_server_id: server.id, name: "pgvector", state: "bogus")
        end
      }.to raise_error(Sequel::ValidationFailed, "state is invalid")
    end
  end

  describe "root-only CHECK constraints" do
    it "rejects extension state on read replicas but allows it on roots and PITR children" do
      root = create_postgres_resource(project:, location_id:)
      expect { root.update(desired_extensions: {"pgvector" => "0.7"}) }.not_to raise_error

      rr = create_postgres_resource(project:, location_id:)
      rr.update(parent_id: root.id)
      expect {
        DB.transaction(savepoint: true) { rr.this.update(desired_extensions: Sequel.pg_jsonb({"pgvector" => "0.7"})) }
      }.to raise_error(Sequel::CheckConstraintViolation)
      expect {
        DB.transaction(savepoint: true) { rr.this.update(extension_config: Sequel.pg_jsonb({"pgvector" => {}})) }
      }.to raise_error(Sequel::CheckConstraintViolation)

      pitr = create_postgres_resource(project:, location_id:)
      pitr.update(parent_id: root.id, restore_target: Time.now)
      expect { pitr.update(desired_extensions: {"pgvector" => "0.7"}) }.not_to raise_error
    end
  end
end
