# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Clover, "postgres" do
  let(:user) { create_account }

  let(:project) { project_with_default_policy(user) }

  let(:pg) do
    Prog::Postgres::PostgresResourceNexus.assemble(
      project_id: project.id,
      location_id: Location::HETZNER_FSN1_ID,
      name: "pg-with-permission",
      target_vm_size: "standard-2",
      target_storage_size_gib: 128
    ).subject
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      postgres_project = Project.create_with_id(name: "default")
      allow(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id)

      [
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/test-postgres"],
        [:delete, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"],
        [:delete, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}"],
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"],
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/read-replica"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/promote"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule"],
        [:delete, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/foo_ubid"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/restore"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/restore"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/reset-superuser-password"],
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/ca-certificates"]
      ].each do |method, path|
        send method, path

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
      postgres_project = Project.create_with_id(name: "default")
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
          location_id: Location::HETZNER_FSN1_ID,
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

      it "location not exist" do
        post "/project/#{project.ubid}/location/not-exist-location/postgres/test-postgres", {
          size: "standard-2",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(404, "Validation failed for following path components: location")
      end

      it "can update database properties" do
        expect(Project).to receive(:from_ubid).and_return(project)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(pg.representative_server).to receive(:storage_size_gib).and_return(128)

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}", {
          size: "standard-8",
          storage_size: 256,
          ha_type: "async"
        }.to_json

        expect(pg.reload.target_vm_size).to eq("standard-8")
        expect(pg.reload.target_storage_size_gib).to eq(256)
        expect(pg.reload.ha_type).to eq("async")
        expect(last_response.status).to eq(200)
      end

      it "can scale down storage if the requested size is enough for existing data" do
        expect(Project).to receive(:from_ubid).and_return(project)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(pg.representative_server).to receive(:storage_size_gib).and_return(128)
        expect(pg.representative_server.vm.sshable).to receive(:cmd).and_return("10000000\n")

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}", {
          storage_size: 64
        }.to_json

        expect(pg.reload.target_storage_size_gib).to eq(64)
      end

      it "does not scale down storage if the requested size is too small for existing data" do
        expect(Project).to receive(:from_ubid).and_return(project)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(pg.representative_server).to receive(:storage_size_gib).and_return(128)
        expect(pg.representative_server.vm.sshable).to receive(:cmd).and_return("999999999\n")

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}", {
          storage_size: 64
        }.to_json

        expect(pg.reload.target_storage_size_gib).to eq(128)
        expect(last_response).to have_api_error(400, "Validation failed for following fields: storage_size", {"storage_size" => "Insufficient storage size is requested. It is only possible to reduce the storage size if the current usage is less than 80% of the requested size."})
      end

      it "returns error message if current usage is unknown" do
        expect(Project).to receive(:from_ubid).and_return(project)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(pg.representative_server).to receive(:storage_size_gib).and_return(128)
        expect(pg.representative_server.vm.sshable).to receive(:cmd).and_raise(StandardError.new("error"))

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}", {
          storage_size: 64
        }.to_json

        expect(pg.reload.target_storage_size_gib).to eq(128)
        expect(last_response).to have_api_error(400, "Database is not ready for update")
      end

      it "read-replica" do
        expect(Project).to receive(:from_ubid).and_return(project)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/#{pg.name}/read-replica", {
          name: "my-read-replica"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "promote" do
        expect(Project).to receive(:from_ubid).and_return(project)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        pg.update(parent_id: pg.id)
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/promote"

        expect(last_response.status).to eq(200)
      end

      it "fails to promote if not read_replica" do
        expect(Project).to receive(:from_ubid).and_return(project)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/promote"

        expect(last_response).to have_api_error(400, "Non read replica servers cannot be promoted.")
      end

      it "firewall-rule" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule", {
          cidr: "0.0.0.0/24"
        }.to_json

        expect(JSON.parse(last_response.body)["cidr"]).to eq("0.0.0.0/24")
        expect(last_response.status).to eq(200)
      end

      it "firewall-rule pg ubid" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/firewall-rule", {
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
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "can set maintenance window" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/set-maintenance-window", {
          maintenance_window_start_at: "9"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(pg.reload.maintenance_window_start_at).to eq(9)

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/set-maintenance-window", {
          maintenance_window_start_at: 12
        }.to_json

        expect(last_response.status).to eq(200)
        expect(pg.reload.maintenance_window_start_at).to eq(12)

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/set-maintenance-window"

        expect(last_response.status).to eq(200)
        expect(pg.reload.maintenance_window_start_at).to be_nil

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/set-maintenance-window", {
          maintenance_window_start_at: 25
        }.to_json

        expect(last_response.status).to eq(400)
        expect(pg.reload.maintenance_window_start_at).to be_nil
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
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq(pg.name)
      end

      it "not found" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/not-exists-pg"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "show firewall" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/firewall-rule"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"][0]["cidr"]).to eq("0.0.0.0/0")
        expect(JSON.parse(last_response.body)["count"]).to eq(1)
      end
    end

    describe "ca-certificates" do
      it "cannot download ca-certificates if not ready" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/ca-certificates"
        expect(last_response.status).to eq(404)
      end

      it "can download ca-certificates when ready" do
        pg.update(root_cert_1: "root_cert_1", root_cert_2: "root_cert_2")

        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/ca-certificates"
        expect(last_response.status).to eq(200)
        header "Content-Type", "application/x-pem-file"
        header "Content-Disposition", "attachment; filename=\"#{pg.name}.pem\""
        expect(last_response.body).to eq("root_cert_1\nroot_cert_2")
      end
    end

    describe "delete" do
      it "success" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "success ubid" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be true
      end

      it "not exist" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/foo-name"

        expect(last_response.status).to eq(204)
        expect(SemSnap.new(pg.id).set?("destroy")).to be false
      end

      it "firewall-rule" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/#{pg.firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule ubid" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/firewall-rule/#{pg.firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule not exist" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/pf000000000000000000000000"

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
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metric-destination/et000000000000000000000000"

        expect(last_response.status).to eq(204)
      end
    end
  end
end
