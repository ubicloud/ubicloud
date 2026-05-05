# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "postgres inject-failure" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }

  before do
    login_api
    postgres_project = Project.create(name: "default")
    allow(Config).to receive_messages(postgres_service_project_id: postgres_project.id, enable_failure_injection: true)
  end

  def create_pg(name)
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name:,
      target_vm_size: "standard-2",
      target_storage_size_gib: 128,
    ).subject
  end

  # Temporarily replaces _cmd on the SSH module for the duration of the block,
  # restoring the original method in ensure to prevent leaking across examples.
  def with_stub_sshable(cmds = [], raise_error: nil)
    original = NetSsh::WarnUnsafe::Sshable.instance_method(:_cmd)
    NetSsh::WarnUnsafe::Sshable.define_method(:_cmd) do |cmd, **|
      cmds << cmd
      raise raise_error if raise_error
      ""
    end
    yield cmds
  ensure
    NetSsh::WarnUnsafe::Sshable.define_method(:_cmd, original)
  end

  def inject_failure_path(pg_or_name)
    name_or_id = pg_or_name.is_a?(String) ? pg_or_name : pg_or_name.name
    location = pg_or_name.respond_to?(:display_location) ? pg_or_name.display_location : "eu-central-h1"
    "/project/#{project.ubid}/location/#{location}/postgres/#{name_or_id}/inject-failure"
  end

  describe "POST /project/:project_id/location/:location/postgres/:pg_name/inject-failure" do
    it "returns 403 when failure injection is disabled" do
      allow(Config).to receive(:enable_failure_injection).and_return(false)
      pg = create_pg("test-pg-disabled")
      post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "message")).to eq("Failure injection is not enabled for this deployment")
    end

    it "returns 404 for nonexistent postgres resource" do
      post inject_failure_path("nonexistent"), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(404)
    end

    it "rejects missing failure_type at schema validation" do
      pg = create_pg("test-pg-missing")
      expect {
        post inject_failure_path(pg), "{}"
      }.to raise_error(Committee::InvalidRequest, /missing required parameters: failure_type/)
    end

    it "rejects invalid failure_type at schema validation" do
      pg = create_pg("test-pg-invalid")
      expect {
        post inject_failure_path(pg), {failure_type: "invalid"}.to_json
      }.to raise_error(Committee::InvalidRequest, /isn't part of the enum/)
    end

    it "injects pg_restart failure" do
      pg = create_pg("test-pg-restart")
      version = pg.representative_server.version
      with_stub_sshable do |cmds|
        post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        expect(last_response.status).to eq(204)
        expect(last_response.body).to be_empty
        expect(cmds).to include("sudo pg_ctlcluster #{version} main restart")
      end
    end

    it "propagates SSH errors for pg_restart" do
      pg = create_pg("test-pg-restart-fail")
      with_stub_sshable(raise_error: Errno::ECONNREFUSED) do
        expect {
          post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        }.to raise_error(Errno::ECONNREFUSED)
      end
    end

    it "handles SSH errors gracefully for os_shutdown" do
      pg = create_pg("test-pg-shutdown")
      with_stub_sshable(raise_error: Errno::ECONNRESET) do
        post inject_failure_path(pg), {failure_type: "os_shutdown"}.to_json
        expect(last_response.status).to eq(204)
      end
    end

    it "injects pg_service_stop failure" do
      pg = create_pg("test-pg-svc-stop")
      version = pg.representative_server.version
      with_stub_sshable do |cmds|
        post inject_failure_path(pg), {failure_type: "pg_service_stop"}.to_json
        expect(last_response.status).to eq(204)
        expect(cmds).to include("sudo pg_ctlcluster #{version} main stop -m smart")
      end
    end

    it "looks up postgres resource by UBID" do
      pg = create_pg("test-pg-ubid")
      with_stub_sshable do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/inject-failure",
          {failure_type: "pg_restart"}.to_json
        expect(last_response.status).to eq(204)
      end
    end

    it "writes an audit_log entry tagged with the failure type" do
      pg = create_pg("test-pg-audit")
      with_stub_sshable do
        expect {
          post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
        }.to change { DB[:audit_log].where(action: "inject_failure_pg_restart").count }.by(1)
        expect(last_response.status).to eq(204)
      end
    end

    it "returns 400 when the resource has no representative server" do
      pg = create_pg("test-pg-no-server")
      # Demote all servers so PostgresResource#representative_server returns nil.
      # allow_any_instance_of doesn't work in frozen mode (the model class is frozen).
      pg.servers_dataset.update(is_representative: false)
      post inject_failure_path(pg), {failure_type: "pg_restart"}.to_json
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message"))
        .to eq("No representative server found for this database")
    end
  end
end
