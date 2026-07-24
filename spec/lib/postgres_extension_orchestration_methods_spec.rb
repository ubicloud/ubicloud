# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresExtensionOrchestrationMethods do
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

  let(:resource) {
    pg = create_postgres_resource(project:, location_id:)
    pg.update(desired_extensions: {"pgvector" => "0.7"})
    pg
  }
  let(:representative) { make_server(resource, representative: true) }
  let(:standby) { make_server(resource) }
  let(:rr_resource) {
    pg = create_postgres_resource(project:, location_id:)
    pg.update(parent_id: resource.id)
    pg
  }
  let(:rr_server) { make_server(rr_resource) }
  let(:cluster) { [representative, standby, rr_server] }

  def make_server(resource, representative: false)
    vm = create_hosted_vm(project, private_subnet, "pg-ext-vm-#{SecureRandom.hex(4)}")
    PostgresServer.create(
      timeline:, resource:, vm_id: vm.id, is_representative: representative,
      synchronization_status: "ready", timeline_access: representative ? "push" : "fetch", version: "17",
    )
  end

  def ext_row(server, state:, name: "pgvector", installed: nil, at: Time.now)
    PostgresServerExtension.create(
      postgres_server_id: server.id, name:, state:,
      installed_version: installed, last_transition_at: at,
    )
  end

  describe "#needs_extension_convergence?" do
    it "is true until every cluster server has a ready row at the desired version" do
      cluster
      expect(resource.needs_extension_convergence?).to be true

      cluster.each { ext_row(it, state: "ready", installed: "0.7") }
      expect(resource.needs_extension_convergence?).to be false
    end

    it "is false with no desired extensions or while a failed row holds retry" do
      cluster
      resource.update(desired_extensions: {})
      expect(resource.needs_extension_convergence?).to be false

      resource.update(desired_extensions: {"pgvector" => "0.7"})
      ext_row(standby, state: "failed")
      expect(resource.needs_extension_convergence?).to be false
    end
  end

  describe "#has_stalled_extension_row?" do
    it "is true only for non-terminal rows older than 10 minutes" do
      row = ext_row(standby, state: "installing", at: Time.now - 5 * 60)
      expect(resource.has_stalled_extension_row?).to be false

      row.update(last_transition_at: Time.now - 11 * 60)
      expect(resource.has_stalled_extension_row?).to be true

      row.update(state: "ready")
      expect(resource.has_stalled_extension_row?).to be false
    end
  end

  describe "#has_failed_extension_row? and #has_active_extension_work?" do
    it "distinguishes failed rows from in-flight rows across the cluster" do
      cluster
      expect(resource.has_failed_extension_row?).to be false
      expect(resource.has_active_extension_work?).to be false

      ext_row(rr_server, state: "failed")
      expect(resource.has_failed_extension_row?).to be true
      expect(resource.has_active_extension_work?).to be false

      ext_row(standby, state: "restart_pending", installed: "0.7")
      expect(resource.has_active_extension_work?).to be true
    end

    it "ignores rows whose extension is no longer desired" do
      cluster
      ext_row(standby, state: "sync_pending", installed: "0.7")
      ext_row(rr_server, state: "failed")
      ext_row(representative, state: "installing", at: Time.now - 11 * 60)
      resource.update(desired_extensions: {})

      expect(resource.has_active_extension_work?).to be false
      expect(resource.has_failed_extension_row?).to be false
      expect(resource.has_stalled_extension_row?).to be false
    end
  end

  describe "#representative_install_unblocked?" do
    it "is false when the representative's row exists in a non-pending state" do
      cluster
      ext_row(representative, state: "installing")
      expect(resource.representative_install_unblocked?("pgvector", "0.7")).to be false
    end

    it "is true with no peers" do
      solo = create_postgres_resource(project:, location_id:)
      make_server(solo, representative: true)
      expect(solo.representative_install_unblocked?("pgvector", "0.7")).to be true
    end

    it "requires every peer (including RR servers) installed at the desired version" do
      cluster
      ext_row(representative, state: "install_pending")
      ext_row(standby, state: "sync_pending", installed: "0.7")
      expect(resource.representative_install_unblocked?("pgvector", "0.7")).to be false

      rr_row = ext_row(rr_server, state: "install_pending")
      expect(resource.representative_install_unblocked?("pgvector", "0.7")).to be false

      rr_row.update(state: "ready", installed_version: "0.7")
      expect(resource.representative_install_unblocked?("pgvector", "0.7")).to be true

      rr_row.update(installed_version: "0.6")
      expect(resource.representative_install_unblocked?("pgvector", "0.7")).to be false
    end
  end

  describe "#restart_unblocked?" do
    it "unblocks the representative's restart only when HA standbys are ready at the version, excluding read replica servers" do
      cluster
      ext_row(standby, state: "restart_pending", installed: "0.7")
      expect(resource.restart_unblocked?(representative.id, "pgvector", "0.7")).to be false

      PostgresServerExtension.where(postgres_server_id: standby.id).update(state: "ready")
      expect(resource.restart_unblocked?(representative.id, "pgvector", "0.7")).to be true
    end

    it "is true for the representative with no HA standbys" do
      representative
      expect(resource.restart_unblocked?(representative.id, "pgvector", "0.7")).to be true
    end

    it "unblocks a standby's restart only when the representative has installed at the desired version" do
      cluster
      expect(resource).not_to be_restart_unblocked(standby.id, "pgvector", "0.7")

      representative_row = ext_row(representative, state: "installing")
      expect(resource.restart_unblocked?(standby.id, "pgvector", "0.7")).to be false

      representative_row.update(state: "restart_pending", installed_version: "0.7")
      expect(resource.restart_unblocked?(standby.id, "pgvector", "0.7")).to be true

      representative_row.update(state: "ready", installed_version: "0.6")
      expect(resource.restart_unblocked?(standby.id, "pgvector", "0.7")).to be false
    end

    it "delegates RR resources to the parent's cluster gate" do
      cluster
      ext_row(representative, state: "ready", installed: "0.7")
      expect(rr_resource.restart_unblocked?(rr_server.id, "pgvector", "0.7")).to be true
    end
  end

  describe "#cluster_server_ids_needing_restart" do
    it "includes only unblocked restart_pending rows at the desired version" do
      cluster
      ext_row(representative, state: "restart_pending", installed: "0.7")
      ext_row(standby, state: "ready", installed: "0.7")
      expect(resource.cluster_server_ids_needing_restart).to eq [representative.id]
    end

    it "excludes stale-version rows and still-blocked servers" do
      cluster
      ext_row(representative, state: "restart_pending", installed: "0.6")
      expect(resource.cluster_server_ids_needing_restart).to be_empty

      ext_row(standby, state: "restart_pending", installed: "0.7")
      expect(resource.cluster_server_ids_needing_restart).to be_empty
    end

    it "does not re-bump a server whose row has advanced to verifying" do
      cluster
      ext_row(representative, state: "verifying", installed: "0.7")
      expect(resource.cluster_server_ids_needing_restart).to be_empty
    end

    it "returns at most one server even when several need a restart" do
      cluster
      second_standby = make_server(resource)
      ext_row(representative, state: "restart_pending", installed: "0.7")
      ext_row(standby, state: "restart_pending", installed: "0.7")
      ext_row(second_standby, state: "restart_pending", installed: "0.7")
      ext_row(rr_server, state: "restart_pending", installed: "0.7")
      ids = resource.cluster_server_ids_needing_restart
      expect(ids.size).to eq 1
      expect([standby.id, second_standby.id, rr_server.id]).to include(ids.first)
    end
  end
end
