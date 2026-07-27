# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Prog::Postgres::ConvergePostgresExtensions do
  subject(:nx) { described_class.new(strand) }

  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:postgres_project) { Project.create(name: "postgres-service-project") }
  let(:postgres_resource) {
    pg = create_postgres_resource(project:, location_id:)
    pg.update(desired_extensions: {"pgvector" => "0.7"})
    pg
  }
  let(:postgres_server) {
    create_postgres_server(resource: postgres_resource).tap { it.strand.update(label: "wait") }
  }
  let(:strand) {
    Strand.create(
      prog: "Postgres::ConvergePostgresExtensions", label: "start",
      parent_id: postgres_resource.strand.id,
      stack: [{"subject_id" => postgres_resource.id}],
    )
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
  end

  def ext_row(server, state:, name: "pgvector", installed: nil)
    PostgresServerExtension.create(
      postgres_server_id: server.id, name:, state:, installed_version: installed,
    )
  end

  def create_standby
    create_postgres_server(resource: postgres_resource, is_representative: false).tap { it.strand.update(label: "wait") }
  end

  describe "#start" do
    it "bumps process_extensions on non-primaries and hops to watch" do
      postgres_server
      standby = create_standby
      expect { nx.start }.to hop("watch")
      expect(Semaphore.where(strand_id: standby.id, name: "process_extensions")).not_to be_empty
      expect(Semaphore.where(strand_id: postgres_server.id, name: "process_extensions")).to be_empty
    end
  end

  describe "#watch" do
    it "pages when a row stalls beyond ten minutes and backs off the loop" do
      ext_row(postgres_server, state: "installing").update(last_transition_at: Time.now - 11 * 60)
      expect { nx.watch }.to nap(30)
      expect(Page.first).not_to be_nil
    end

    it "bumps process_extensions without stacking duplicates" do
      postgres_server
      standby = create_standby
      ext_row(standby, state: "install_pending")
      expect { nx.watch }.to nap(5)
      expect { nx.watch }.to nap(5)
      expect(Semaphore.where(strand_id: standby.id, name: "process_extensions").count).to eq(1)
    end

    it "bumps restart for restart_pending rows whose turn has come" do
      ext_row(postgres_server, state: "restart_pending", installed: "0.7")
      expect { nx.watch }.to nap(5)
      expect(Semaphore.where(strand_id: postgres_server.id, name: "restart").count).to eq(1)
    end

    it "does not bump restart for verifying rows" do
      ext_row(postgres_server, state: "verifying", installed: "0.7")
      expect { nx.watch }.to nap(5)
      expect(Semaphore.where(strand_id: postgres_server.id, name: "restart")).to be_empty
    end

    it "advances a sync_pending row matching the published config and bumps configure" do
      row = ext_row(postgres_server, state: "sync_pending", installed: "0.7")
      postgres_resource.update(extension_config: {"pgvector" => {"!version" => "0.7", "!needs_restart" => false}})
      expect { nx.watch }.to nap(5)
      expect(row.reload.state).to eq("config_pending")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "configure")).not_to be_empty
    end

    it "bumps every server after a version change, including the representative" do
      postgres_server
      standby = create_standby
      [postgres_server, standby].each { ext_row(it, state: "ready", installed: "0.7") }
      expect { nx.watch }.to exit({"msg" => "postgres extensions are converged"})

      postgres_resource.update(desired_extensions: {"pgvector" => "0.8"})
      expect { described_class.new(strand).watch }.to nap(5)
      [postgres_server, standby].each do |server|
        expect(Semaphore.where(strand_id: server.id, name: "process_extensions")).not_to be_empty
      end
    end

    it "pops when fully converged or when only failed rows remain, resolving the stall page" do
      ext_row(postgres_server, state: "ready", installed: "0.7")
      page = Prog::PageNexus.assemble("stuck", ["converge_postgres_extensions", postgres_resource.id], postgres_resource.ubid).subject
      expect { nx.watch }.to exit({"msg" => "postgres extensions are converged"})
      expect(page.reload.resolve_set?).to be true

      PostgresServerExtension.dataset.update(state: "failed")
      expect { nx.watch }.to exit({"msg" => "extension install failed"})
    end

    it "pages on failed rows and resolves once a retry clears them" do
      row = ext_row(postgres_server, state: "failed")
      expect { nx.watch }.to exit({"msg" => "extension install failed"})
      page = Page.from_tag_parts("postgres_extension_failed", postgres_resource.id)
      expect(page.severity).to eq("warning")

      row.destroy
      ext_row(postgres_server, state: "ready", installed: "0.7")
      expect { described_class.new(strand).watch }.to exit({"msg" => "postgres extensions are converged"})
      expect(page.reload.resolve_set?).to be true
    end

    it "pops rather than looping on a sync_pending row for an undesired extension" do
      ext_row(postgres_server, state: "sync_pending", installed: "0.7")
      postgres_resource.update(desired_extensions: {})
      expect { nx.watch }.to exit({"msg" => "postgres extensions are converged"})
    end
  end

  describe "#advance_sync_pending_rows" do
    it "advances matching sync_pending rows and bumps configure cluster-wide in one step" do
      postgres_server
      standby = create_standby
      restart_row = ext_row(postgres_server, state: "sync_pending", installed: "0.7")
      config_row = ext_row(standby, state: "sync_pending", name: "pg_cron", installed: "1.6")
      stale_row = ext_row(standby, state: "sync_pending", installed: "0.6")
      postgres_resource.update(
        desired_extensions: {"pgvector" => "0.7", "pg_cron" => "1.6"},
        extension_config: {
          "pgvector" => {"!version" => "0.7", "!needs_restart" => true},
          "pg_cron" => {"!version" => "1.6", "!needs_restart" => false},
        },
      )

      nx.advance_sync_pending_rows
      expect(restart_row.reload.state).to eq("restart_pending")
      expect(config_row.reload.state).to eq("config_pending")
      expect(stale_row.reload.state).to eq("sync_pending")
      [postgres_server, standby].each do |server|
        expect(Semaphore.where(strand_id: server.id, name: "configure")).not_to be_empty
      end
    end

    it "skips extensions whose published !version is stale" do
      row = ext_row(postgres_server, state: "sync_pending", installed: "0.7")
      postgres_resource.update(extension_config: {"pgvector" => {"!version" => "0.6", "!needs_restart" => false}})
      nx.advance_sync_pending_rows
      expect(row.reload.state).to eq("sync_pending")
      expect(Semaphore.where(strand_id: postgres_server.id, name: "configure")).to be_empty
    end

    it "does not bump configure when no rows advance" do
      ext_row(postgres_server, state: "ready", installed: "0.7")
      ext_row(postgres_server, state: "sync_pending", name: "pg_cron", installed: "1.5")
      postgres_resource.update(
        desired_extensions: {"pgvector" => "0.7", "pg_cron" => "1.6"},
        extension_config: {
          "pgvector" => {"!version" => "0.7", "!needs_restart" => false},
          "pg_cron" => {"!version" => "1.6", "!needs_restart" => false},
        },
      )
      nx.advance_sync_pending_rows
      expect(Semaphore.where(strand_id: postgres_server.id, name: "configure")).to be_empty
    end
  end
end
