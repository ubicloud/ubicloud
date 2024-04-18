# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "postgres" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:project_wo_permissions) { user.create_project_with_default_policy("project-2", policy_body: []) }

  let(:pg) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location: "hetzner-fsn1",
      name: "pg-with-permission",
      target_vm_size: "standard-2",
      target_storage_size_gib: 100
    ).subject
  end

  let(:pg_wo_permission) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project_wo_permissions.id,
      location: "hetzner-fsn1",
      name: "pg-without-permission",
      target_vm_size: "standard-2",
      target_storage_size_gib: 100
    ).subject
  end

  describe "unauthenticated" do
    before do
      postgres_project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    it "not location list" do
      get "/api/project/#{project.ubid}/location/#{pg.location}/postgres"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not create" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/postgres_name"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not delete" do
      delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not delete ubid" do
      delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not get" do
      get "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not get ubid" do
      get "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not create firewall rule" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/firewall-rule"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not delete firewall rule" do
      delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/firewall-rule/foo_ubid"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not restore" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/restore"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not restore ubid" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}/restore"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not reset super user password" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/reset-superuser-password"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end

    it "not reset super user password ubid" do
      post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}/reset-superuser-password"

      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Please login to continue")
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
      postgres_project = Project.create_with_id(name: "default", provider: "hetzner").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    describe "list" do
      it "empty" do
        get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "success single" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/postgres"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(1)
      end

      it "success multiple" do
        Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: project.id,
          location: "hetzner-fsn1",
          name: "pg-test-2",
          target_vm_size: "standard-2",
          target_storage_size_gib: 100
        )

        get "/api/project/#{project.ubid}/location/#{pg.location}/postgres"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(2)
      end
    end

    describe "create" do
      it "success" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/test-postgres", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres")
      end

      it "invalid name" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/INVALIDNAME", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["name"]).to eq("Name must only contain lowercase letters, numbers, and hyphens and have max length 63.")
      end

      it "invalid body" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/test-pg", "invalid_body"

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["body"]).to eq("Request body isn't a valid JSON object.")
      end

      it "missing required key" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/test-pg", {
          unix_user: "ha_type"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["body"]).to eq("Request body must include required parameters: size")
      end

      it "non allowed key" do
        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/test-pg", {
          size: "standard-2",
          foo_key: "foo_val"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["body"]).to eq("Only following parameters are allowed: size, ha_type")
      end

      it "firewall-rule" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/firewall-rule", {
          cidr: "0.0.0.0/24"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "firewall-rule pg ubid" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}/firewall-rule", {
          cidr: "0.0.0.0/24"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "firewall-rule invalid cidr" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/firewall-rule", {
          cidr: "0.0.0"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["CIDR"]).to eq("Invalid CIDR")
      end

      it "restore" do
        stub_const("Backup", Struct.new(:last_modified))
        restore_target = Time.now.utc
        pg.timeline.update(earliest_backup_completed_at: restore_target - 10 * 60)
        expect(pg.timeline).to receive(:refresh_earliest_backup_completion_time).and_return(restore_target - 10 * 60)
        expect(PostgresResource).to receive(:[]).with(pg.id).and_return(pg)
        expect(PostgresResource).to receive(:[]).and_call_original.at_least(:once)
        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/restore", {
          name: "restored-pg",
          restore_target: restore_target

        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "restore invalid target" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/restore", {
          name: "restored-pg",
          restore_target: Time.now.utc
        }.to_json

        expect(last_response.status).to eq(400)
      end

      it "reset password" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "reset password invalid restore" do
        pg.representative_server.update(timeline_access: "fetch")

        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Superuser password cannot be updated during restore!")
      end

      it "invalid password" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "dummy"
        }.to_json

        expect(last_response.status).to eq(400)
      end

      it "reset password ubid" do
        post "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "invalid payment" do
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key")

        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/test-postgres", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Validation failed for following fields: billing_info")
      end
    end

    describe "show" do
      it "success" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(pg.name)
      end

      it "success ubid" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(pg.name)
      end

      it "not found" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/postgres/not-exists-pg"

        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "show firewall" do
        get "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}/firewall-rule"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)[0]["cidr"]).to eq("0.0.0.0/0")
      end
    end

    describe "delete" do
      it "success" do
        delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "success ubid" do
        delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "not exist" do
        delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/foo_name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "not exist ubid" do
        delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/foo_ubid"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "firewall-rule" do
        delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/firewall-rule/#{pg.firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule ubid" do
        delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/id/#{pg.ubid}/firewall-rule/#{pg.firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule not exist" do
        delete "/api/project/#{project.ubid}/location/#{pg.location}/postgres/#{pg.name}/firewall-rule/foo_ubid"

        expect(last_response.status).to eq(204)
      end
    end
  end
end
