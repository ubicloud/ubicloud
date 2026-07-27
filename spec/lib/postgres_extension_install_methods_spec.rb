# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresExtensionInstallMethods do
  subject(:nx) { Prog::Postgres::PostgresServerNexus.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_timeline) { create_postgres_timeline(location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource, timeline: postgres_timeline) }
  let(:st) { postgres_server.strand }
  let(:server) { nx.postgres_server }
  let(:sshable) { server.vm.sshable }
  let(:service_project) { Project.create(name: "postgres-service-project") }
  let(:desired) { {"pgvector" => "0.7"} }

  before do
    allow(Config).to receive_messages(postgres_service_project_id: service_project.id, postgres_extension_script_base_url: "s3://ext-bucket/scripts")
    postgres_resource.update(desired_extensions: desired)
  end

  def ext_row(target_server = server, state:, name: "pgvector", installed: nil, target: nil)
    PostgresServerExtension.create(
      postgres_server_id: target_server.id, name:, state:,
      installed_version: installed, target_version: target,
    )
  end

  def result_json(status: "ok", config_entries: {}, needs_restart: false, error: nil)
    JSON.generate({status:, config_entries:, needs_restart:, error:}.compact)
  end

  describe "#extension_install_command" do
    it "carries the full INSTALL_* env contract and a single-line payload" do
      cmd = nx.extension_install_command("pgvector", "0.7", "install")
      env_args = cmd[1..-4]
      expect(env_args).to include(
        "INSTALL_PHASE=install", "INSTALL_NAME=pgvector", "INSTALL_VERSION=0.7",
        "INSTALL_PG_MAJOR=#{server.version}", "INSTALL_RESOURCE_ID=#{postgres_resource.ubid}",
        "INSTALL_SERVER_ID=#{server.id}", "INSTALL_SERVER_ROLE=primary",
        "INSTALL_SERVER_FLAVOR=standard",
        "INSTALL_SCRIPT_BASE_URL=s3://ext-bucket/scripts",
        "INSTALL_RESULT_FILE=/tmp/extension-result-pgvector-install.json",
      )
      expect(cmd.last).to include("rm -f '/tmp/extension-result-pgvector-install.json'")
      expect(cmd.last).to include("aws s3 cp 's3://ext-bucket/scripts/pgvector/#{server.version}/install.sh'")
      # Shellwords escapes newlines as bash line continuations, which garbles
      # multiline payloads on the VM; the payload must stay single-line.
      expect(cmd.last).not_to include("\n")
    end

    it "reports standby and read_replica roles" do
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      expect(Prog::Postgres::PostgresServerNexus.new(standby.strand).extension_install_command("pgvector", "0.7", "install")).to include("INSTALL_SERVER_ROLE=standby")

      replica_resource = create_postgres_resource(project:, location_id:)
      replica_resource.update(parent_id: postgres_resource.id)
      replica = create_postgres_server(resource: replica_resource, timeline: postgres_timeline, timeline_access: "fetch", is_representative: true)
      expect(Prog::Postgres::PostgresServerNexus.new(replica.strand).extension_install_command("pgvector", "0.7", "install")).to include("INSTALL_SERVER_ROLE=read_replica")
    end
  end

  describe "#process_extensions" do
    it "creates install_pending rows for desired extensions without rows and ignores undesired rows" do
      ext_row(state: "ready", name: "leftover", installed: "1.0")
      allow(sshable).to receive(:d_run)
      nx.process_extensions
      row = PostgresServerExtension.first(postgres_server_id: server.id, name: "pgvector")
      expect(row).not_to be_nil
      expect(PostgresServerExtension.first(postgres_server_id: server.id, name: "leftover").state).to eq("ready")
    end

    it "recycles extensions installed at a stale version to install_pending, clearing target_version" do
      rows = {
        "a" => ext_row(state: "sync_pending", name: "a", installed: "0.6", target: "0.6"),
        "b" => ext_row(state: "config_pending", name: "b", installed: "0.6", target: "0.6"),
        "c" => ext_row(state: "ready", name: "c", installed: "0.6", target: "0.6"),
      }
      postgres_resource.update(desired_extensions: {"a" => "0.7", "b" => "0.7", "c" => "0.7"})
      nx.process_extensions
      rows.each_value do |row|
        expect(row.reload.state).to eq("install_pending")
        expect(row.target_version).to be_nil
      end
    end

    it "drains the post_restart unit before recycling a stale verifying row" do
      row = ext_row(state: "verifying", installed: "0.6", target: "0.6")
      expect(sshable).to receive(:d_check).with("extension_pgvector_post_restart").and_return("InProgress")
      nx.process_extensions
      expect(row.reload.state).to eq("verifying")

      expect(sshable).to receive(:d_check).with("extension_pgvector_post_restart").and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with("extension_pgvector_post_restart")
      nx.process_extensions
      expect(row.reload.state).to eq("install_pending")
    end

    it "recycles a stale verifying row directly when its post_restart unit never started" do
      row = ext_row(state: "verifying", installed: "0.6", target: "0.6")
      expect(sshable).to receive(:d_check).with("extension_pgvector_post_restart").and_return("NotStarted")
      nx.process_extensions
      expect(row.reload.state).to eq("install_pending")
    end

    it "leaves a stale verifying row alone while its unit is in a transient state" do
      row = ext_row(state: "verifying", installed: "0.6", target: "0.6")
      expect(sshable).to receive(:d_check).with("extension_pgvector_post_restart").and_return("Unknown")
      expect(sshable).not_to receive(:d_clean)
      nx.process_extensions
      expect(row.reload.state).to eq("verifying")
    end

    it "leaves an installing row alone while its unit is in a transient state" do
      row = ext_row(state: "installing", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Unknown")
      expect(sshable).not_to receive(:d_clean)
      nx.process_extensions
      expect(row.reload.state).to eq("installing")
    end

    it "fires the install and stamps target_version from install_pending when the representative's install is unblocked" do
      row = ext_row(state: "install_pending")
      expect(sshable).to receive(:d_run) { |unit, *args| expect(unit).to eq("extension_pgvector_install") }
      nx.process_extensions
      expect(row.reload.state).to eq("installing")
      expect(row.target_version).to eq("0.7")
    end

    it "holds the primary's install while a peer is not yet installed at the desired version" do
      create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      row = ext_row(state: "install_pending")
      expect(sshable).not_to receive(:d_run)
      nx.process_extensions
      expect(row.reload.state).to eq("install_pending")
    end

    it "records installed_version from target_version, not current desired (mid-install version bump)" do
      row = ext_row(state: "installing", target: "0.7")
      postgres_resource.update(desired_extensions: {"pgvector" => "0.8"})
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-install.json").and_return(result_json)
      expect(sshable).to receive(:d_clean).with("extension_pgvector_install")
      nx.process_extensions
      expect(row.reload.installed_version).to eq("0.7")
      expect(row.state).to eq("ready")
    end

    it "re-runs a lost install unit with the launched version" do
      ext_row(state: "installing", target: "0.7")
      postgres_resource.update(desired_extensions: {"pgvector" => "0.8"})
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("NotStarted")
      expect(sshable).to receive(:d_run) { |_, *args| expect(args).to include("INSTALL_VERSION=0.7") }
      nx.process_extensions
    end

    it "re-runs install from sync_pending on the primary when extension_config !version is stale" do
      row = ext_row(state: "sync_pending", installed: "0.7", target: "0.7")
      expect(sshable).to receive(:d_run)
      nx.process_extensions
      expect(row.reload.state).to eq("installing")
      expect(row.target_version).to eq("0.7")
    end

    it "leaves sync_pending alone on the primary when extension_config !version matches" do
      row = ext_row(state: "sync_pending", installed: "0.7", target: "0.7")
      postgres_resource.update(extension_config: {"pgvector" => {"!version" => "0.7"}})
      expect(sshable).not_to receive(:d_run)
      nx.process_extensions
      expect(row.reload.state).to eq("sync_pending")
    end

    it "does not re-run install from sync_pending on a standby" do
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = Prog::Postgres::PostgresServerNexus.new(standby.strand)
      row = ext_row(standby, state: "sync_pending", installed: "0.7", target: "0.7")
      expect(standby_nx.postgres_server.vm.sshable).not_to receive(:d_run)
      standby_nx.process_extensions
      expect(row.reload.state).to eq("sync_pending")
    end

    it "promotes config_pending to ready only once the :configure bump is consumed" do
      row = ext_row(state: "config_pending", installed: "0.7", target: "0.7")
      server.incr_configure
      nx.process_extensions
      expect(row.reload.state).to eq("config_pending")

      server.decr_configure
      server.reload
      nx.process_extensions
      expect(row.reload.state).to eq("ready")
    end

    it "takes no action on restart_pending rows" do
      row = ext_row(state: "restart_pending", installed: "0.7", target: "0.7")
      expect(sshable).not_to receive(:d_check)
      expect(sshable).not_to receive(:d_run)
      nx.process_extensions
      expect(row.reload.state).to eq("restart_pending")
    end

    it "fires and tracks the post_restart unit from verifying" do
      row = ext_row(state: "verifying", installed: "0.7", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_post_restart").and_return("NotStarted")
      expect(sshable).to receive(:d_run) { |unit, *args| expect(args).to include("INSTALL_PHASE=post_restart") }
      nx.process_extensions

      expect(sshable).to receive(:d_check).with("extension_pgvector_post_restart").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-post_restart.json").and_return(result_json)
      expect(sshable).to receive(:d_clean).with("extension_pgvector_post_restart")
      nx.process_extensions
      expect(row.reload.state).to eq("ready")
    end

    it "skips verifying while a restart is queued" do
      ext_row(state: "verifying", installed: "0.7", target: "0.7")
      server.incr_restart
      expect(sshable).not_to receive(:d_check)
      nx.process_extensions
    end

    it "marks the row failed when the unit fails or the result is unreadable" do
      row = ext_row(state: "installing", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Failed")
      expect(sshable).to receive(:d_clean).with("extension_pgvector_install")
      nx.process_extensions
      expect(row.reload.state).to eq("failed")
      expect(row.last_error).to eq("install d_run failed")

      row.update(state: "installing", last_error: nil)
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-install.json").and_return("not json")
      expect(sshable).to receive(:d_clean).with("extension_pgvector_install")
      nx.process_extensions
      expect(row.reload.state).to eq("failed")
      expect(row.last_error).to start_with("result file unreadable")
    end

    it "marks the row failed when the script reports an error" do
      row = ext_row(state: "installing", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-install.json").and_return(result_json(status: "error", error: "deb missing"))
      expect(sshable).to receive(:d_clean).with("extension_pgvector_install")
      nx.process_extensions
      expect(row.reload.state).to eq("failed")
      expect(row.last_error).to eq("deb missing")
    end

    it "marks the row failed when the result has the wrong shape" do
      row = ext_row(state: "installing", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-install.json").and_return(JSON.generate({status: "ok", needs_restart: "false"}))
      expect(sshable).to receive(:d_clean).with("extension_pgvector_install")
      nx.process_extensions
      expect(row.reload.state).to eq("failed")
      expect(row.last_error).to eq("malformed result file for install")
    end

    it "marks the row failed when the result claims driver metadata keys" do
      row = ext_row(state: "installing", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-install.json").and_return(result_json(config_entries: {"!version" => "evil"}))
      expect(sshable).to receive(:d_clean).with("extension_pgvector_install")
      nx.process_extensions
      expect(row.reload.state).to eq("failed")
      expect(row.last_error).to eq("malformed result file for install")
    end

    it "leaves installing rows in place while the unit runs" do
      row = ext_row(state: "installing", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("InProgress")
      nx.process_extensions
      expect(row.reload.state).to eq("installing")
    end

    it "on install success with config entries, the primary transitions to sync_pending and publishes extension_config atomically" do
      row = ext_row(state: "installing", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-install.json").and_return(result_json(config_entries: {"shared_preload_libraries" => "vector"}, needs_restart: true))
      expect(sshable).to receive(:d_clean).with("extension_pgvector_install")
      nx.process_extensions
      expect(row.reload.state).to eq("sync_pending")
      expect(row.installed_version).to eq("0.7")
      expect(postgres_resource.reload.extension_config["pgvector"]).to eq(
        "shared_preload_libraries" => "vector", "!needs_restart" => true, "!version" => "0.7",
      )
    end

    it "does not publish extension_config when no longer the representative" do
      server.update(is_representative: false)
      row = ext_row(state: "installing", target: "0.7")
      expect(sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-install.json").and_return(result_json(config_entries: {"shared_preload_libraries" => "vector"}, needs_restart: true))
      expect(sshable).to receive(:d_clean).with("extension_pgvector_install")
      nx.process_extensions
      expect(row.reload.state).to eq("sync_pending")
      expect(postgres_resource.reload.extension_config).to eq({})
    end

    it "on install success with config entries, a standby transitions without publishing" do
      standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
      standby_nx = Prog::Postgres::PostgresServerNexus.new(standby.strand)
      standby_sshable = standby_nx.postgres_server.vm.sshable
      row = ext_row(standby, state: "installing", target: "0.7")
      expect(standby_sshable).to receive(:d_check).with("extension_pgvector_install").and_return("Succeeded")
      expect(standby_sshable).to receive(:_cmd).with("cat /tmp/extension-result-pgvector-install.json").and_return(result_json(config_entries: {"shared_preload_libraries" => "vector"}, needs_restart: true))
      expect(standby_sshable).to receive(:d_clean).with("extension_pgvector_install")
      standby_nx.process_extensions
      expect(row.reload.state).to eq("sync_pending")
      expect(postgres_resource.reload.extension_config).to eq({})
    end
  end
end
