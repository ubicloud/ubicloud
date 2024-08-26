# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "postgres" do
  let(:user) { create_account }

  let(:project) { user.create_project_with_default_policy("project-1") }

  let(:pg) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location: "hetzner-fsn1",
      name: "pg-with-permission",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128
    ).subject
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      postgres_project = Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)

      [
        [:get, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres"],
        [:post, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/test-postgres"],
        [:delete, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"],
        [:delete, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}"],
        [:get, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"],
        [:get, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}"],
        [:post, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule"],
        [:delete, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/foo_ubid"],
        [:post, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/restore"],
        [:post, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/restore"],
        [:post, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password"],
        [:post, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/reset-superuser-password"],
        [:post, "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/failover"]
      ].each do |method, path|
        send method, path

        expect(last_response).to have_api_error(401, "Please login to continue")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api(user.email)
      postgres_project = Project.create_with_id(name: "default").tap { _1.associate_with_project(_1) }
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)
    end

    describe "list" do
      it "empty" do
        get "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "success single" do
        get "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(1)
      end

      it "success multiple" do
        Prog::Postgres::PostgresResourceNexus.assemble(
          project_id: project.id,
          location: "hetzner-fsn1",
          name: "pg-test-2",
          target_vm_size: "standard-2",
          target_storage_size_gib: 128
        )

        get "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(2)
      end
    end

    describe "create" do
      it "success" do
        post "/api/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-no-ha", {
          size: "standard-2",
          ha_type: "none"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-no-ha")

        post "/api/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-async", {
          size: "standard-2",
          ha_type: "async"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-async")

        post "/api/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-sync", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-sync")
      end

      it "invalid location" do
        post "/api/project/#{project.ubid}/location/eu-north-h1/postgres/test-postgres", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: location", {"location" => "Given location is not a valid postgres location. Available locations: [\"eu-central-h1\"]"})
      end

      it "invalid name" do
        post "/api/project/#{project.ubid}/location/eu-central-h1/postgres/INVALIDNAME", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: name", {"name" => "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."})
      end

      it "invalid body" do
        post "/api/project/#{project.ubid}/location/eu-central-h1/postgres/test-pg", "invalid_body"

        expect(last_response).to have_api_error(400, "Validation failed for following fields: body", {"body" => "Request body isn't a valid JSON object."})
      end

      it "missing required key" do
        post "/api/project/#{project.ubid}/location/eu-central-h1/postgres/test-pg", {
          unix_user: "ha_type"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: body", {"body" => "Request body must include required parameters: size"})
      end

      it "non allowed key" do
        post "/api/project/#{project.ubid}/location/eu-central-h1/postgres/test-pg", {
          size: "standard-2",
          foo_key: "foo_val"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: body", {"body" => "Only following parameters are allowed: size, storage_size, ha_type"})
      end

      it "firewall-rule" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule", {
          cidr: "0.0.0.0/24"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "firewall-rule pg ubid" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/firewall-rule", {
          cidr: "0.0.0.0/24"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "firewall-rule invalid cidr" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule", {
          cidr: "0.0.0"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: cidr", {"cidr" => "Invalid CIDR"})
      end

      it "metric-destination" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination", {
          url: "https://example.com",
          username: "username",
          password: "password"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "metric-destination invalid url" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination", {
          url: "-",
          username: "username",
          password: "password"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["url"]).to eq("Invalid URL scheme. Only https URLs are supported.")
      end

      it "restore" do
        stub_const("Backup", Struct.new(:key, :last_modified))
        restore_target = Time.now.utc
        expect(MinioCluster).to receive(:[]).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
        expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, list_objects: [Backup.new("basebackups_005/backup_stop_sentinel.json", restore_target - 10 * 60)])).at_least(:once)

        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/restore", {
          name: "restored-pg",
          restore_target: restore_target

        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "restore invalid target" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/restore", {
          name: "restored-pg",
          restore_target: Time.now.utc
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: restore_target")
      end

      it "reset password" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "reset password invalid restore" do
        pg.representative_server.update(timeline_access: "fetch")

        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response).to have_api_error(400, "Superuser password cannot be updated during restore!")
      end

      it "invalid password" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "dummy"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: password")
      end

      it "reset password ubid" do
        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "failover" do
        project.set_ff_postgresql_base_image(true)
        expect(PostgresResource).to receive(:[]).and_return(pg)
        expect(pg.representative_server).to receive(:trigger_failover).and_return(true)

        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/failover"

        expect(last_response.status).to eq(200)
      end

      it "failover invalid restore" do
        expect(PostgresResource).to receive(:[]).and_return(pg)
        expect(pg.representative_server).to receive(:primary?).and_return(false)

        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/failover"

        expect(last_response).to have_api_error(400, "Failover cannot be triggered during restore!")
      end

      it "failover no ff base image" do
        expect(PostgresResource).to receive(:[]).and_return(pg)
        expect(pg.representative_server).to receive(:primary?).and_return(true)

        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/failover"

        expect(last_response).to have_api_error(400, "Failover cannot be triggered for this resource!")
      end

      it "failover no standby" do
        project.set_ff_postgresql_base_image(true)
        expect(PostgresResource).to receive(:[]).and_return(pg)
        expect(pg.representative_server).to receive(:primary?).and_return(true)
        expect(pg.representative_server).to receive(:trigger_failover).and_return(false)

        post "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/failover"

        expect(last_response).to have_api_error(400, "There is not a suitable standby server to failover!")
      end

      it "invalid payment" do
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key")

        post "/api/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/test-postgres", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: billing_info")
      end
    end

    describe "show" do
      it "success" do
        get "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(pg.name)
      end

      it "success ubid" do
        get "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(pg.name)
      end

      it "not found" do
        get "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/not-exists-pg"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "show firewall" do
        get "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/firewall-rule"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)[0]["cidr"]).to eq("0.0.0.0/0")
      end
    end

    describe "delete" do
      it "success" do
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "success ubid" do
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "not exist" do
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/foo_name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "not exist ubid" do
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/foo_ubid"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "not exist ubid in location" do
        delete "/api/project/#{project.ubid}/location/foo_location/postgres/id/#{pg.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "firewall-rule" do
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/#{pg.firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule ubid" do
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/id/#{pg.ubid}/firewall-rule/#{pg.firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule not exist" do
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/foo_ubid"

        expect(last_response.status).to eq(204)
      end

      it "metric-destination" do
        PostgresMetricDestination.create_with_id(
          postgres_resource_id: pg.id,
          url: "https://example.com",
          username: "username",
          password: "password"
        )
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination/#{pg.metric_destinations.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "metric-destination not exist" do
        delete "/api/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination/foo_ubid"

        expect(last_response.status).to eq(204)
      end
    end
  end
end
