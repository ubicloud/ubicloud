# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "postgres" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

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
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/test-postgres"],
        [:delete, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"],
        [:delete, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}"],
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"],
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule"],
        [:delete, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/foo_ubid"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/restore"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/restore"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/reset-superuser-password"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/failover"]
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
        get "/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"]).to eq([])
      end

      it "success single" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres"

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

        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"].length).to eq(2)
      end
    end

    describe "create" do
      it "success" do
        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-no-ha", {
          size: "standard-2",
          ha_type: "none"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-no-ha")

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-async", {
          size: "standard-2",
          ha_type: "async"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-async")

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-sync", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-sync")
      end

      it "sends mail to partners" do
        expect(Config).to receive(:postgres_paradedb_notification_email).and_return("dummy@mail.com")
        expect(Util).to receive(:send_email)

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-no-ha", {
          size: "standard-2",
          flavor: "paradedb"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "invalid location" do
        post "/project/#{project.ubid}/location/eu-north-h1/postgres/test-postgres", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: location", {"location" => "Given location is not a valid postgres location. Available locations: [\"eu-central-h1\", \"us-east-a2\"]"})
      end

      it "invalid name" do
        post "/project/#{project.ubid}/location/eu-central-h1/postgres/INVALIDNAME", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: name", {"name" => "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."})
      end

      it "firewall-rule" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule", {
          cidr: "0.0.0.0/24"
        }.to_json

        expect(JSON.parse(last_response.body)["cidr"]).to eq("0.0.0.0/24")
        expect(last_response.status).to eq(200)
      end

      it "firewall-rule pg ubid" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/firewall-rule", {
          cidr: "0.0.0.0/24"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "firewall-rule invalid cidr" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule", {
          cidr: "0.0.0"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: cidr", {"cidr" => "Invalid CIDR"})
      end

      it "metric-destination" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination", {
          url: "https://example.com",
          username: "username",
          password: "password"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "metric-destination invalid url" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination", {
          url: "-",
          username: "username",
          password: "password"
        }.to_json

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["details"]["url"]).to eq("Invalid URL scheme. Only https URLs are supported.")
      end

      it "restore" do
        backup = Struct.new(:key, :last_modified)
        restore_target = Time.now.utc
        expect(MinioCluster).to receive(:[]).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
        expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, list_objects: [backup.new("basebackups_005/backup_stop_sentinel.json", restore_target - 10 * 60)])).at_least(:once)

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/restore", {
          name: "restored-pg",
          restore_target: restore_target

        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "restore invalid target" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/restore", {
          name: "restored-pg",
          restore_target: Time.now.utc
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: restore_target")
      end

      it "reset password" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "reset password invalid restore" do
        pg.representative_server.update(timeline_access: "fetch")

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response).to have_api_error(400, "Superuser password cannot be updated during restore!")
      end

      it "invalid password" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "dummy"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: password")
      end

      it "reset password ubid" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "failover" do
        project.set_ff_postgresql_base_image(true)
        pg.save_changes
        rs = pg.representative_server
        rs.update(timeline_access: "push")
        st = Prog::Postgres::PostgresServerNexus.assemble(resource_id: pg.id, timeline_id: rs.timeline_id, timeline_access: "fetch")
        st.update(label: "wait")
        expect(PostgresServer).to receive(:run_query).and_return "16/B374D848"

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/failover"

        expect(last_response.status).to eq(200)
      end

      it "failover invalid restore" do
        pg.save_changes
        pg.representative_server.update(timeline_access: "fetch")

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/failover"

        expect(last_response).to have_api_error(400, "Failover cannot be triggered during restore!")
      end

      it "failover no ff base image" do
        pg.save_changes

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/failover"

        expect(last_response).to have_api_error(400, "Failover cannot be triggered for this resource!")
      end

      it "failover no standby" do
        project.set_ff_postgresql_base_image(true)
        pg.save_changes

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/failover"

        expect(last_response).to have_api_error(400, "There is not a suitable standby server to failover!")
      end

      it "invalid payment" do
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key")

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/test-postgres", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: billing_info")
      end
    end

    describe "show" do
      it "success" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(pg.name)
      end

      it "success ubid" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(pg.name)
      end

      it "not found" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/not-exists-pg"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "show firewall" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/firewall-rule"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"][0]["cidr"]).to eq("0.0.0.0/0")
        expect(JSON.parse(last_response.body)["count"]).to eq(1)
      end
    end

    describe "delete" do
      it "success" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "success ubid" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "not exist" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/foo_name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "not exist ubid" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_fooubid"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "not exist ubid in location" do
        delete "/project/#{project.ubid}/location/foo_location/postgres/_#{pg.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "firewall-rule" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/#{pg.firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule ubid" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/_#{pg.ubid}/firewall-rule/#{pg.firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule not exist" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/foo_ubid"

        expect(last_response.status).to eq(204)
      end

      it "metric-destination" do
        PostgresMetricDestination.create_with_id(
          postgres_resource_id: pg.id,
          url: "https://example.com",
          username: "username",
          password: "password"
        )
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination/#{pg.metric_destinations.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "metric-destination not exist" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination/foo_ubid"

        expect(last_response.status).to eq(204)
      end
    end
  end
end
