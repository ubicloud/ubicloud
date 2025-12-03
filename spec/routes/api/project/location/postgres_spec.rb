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
      target_storage_size_gib: 128,
      target_version: "16"
    ).subject
  end

  describe "unauthenticated" do
    it "cannot perform authenticated operations" do
      postgres_project = Project.create(name: "default")
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
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/ca-certificates"],
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics"],
        [:post, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/upgrade"],
        [:get, "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/backup"]
      ].each do |method, path|
        send method, path

        expect(last_response).to have_api_error(401, "must include personal access token in Authorization header")
      end
    end
  end

  describe "authenticated" do
    before do
      login_api
      postgres_project = Project.create(name: "default")
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
          storage_size: "64",
          ha_type: "none"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-no-ha")

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-async", {
          size: "standard-2",
          storage_size: "64",
          ha_type: "async"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-async")

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-sync", {
          size: "standard-2",
          storage_size: "64",
          ha_type: "sync"
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-sync")

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-config", {
          size: "standard-2",
          storage_size: "64",
          ha_type: "none",
          pg_config: {"wal_level" => "logical"}
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-config")

        get "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-config"
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["name"]).to eq("test-postgres-config")

        get "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-config/config"
        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["pg_config"]).to eq({"wal_level" => "logical"})
      end

      it "sends mail to partners" do
        expect(Config).to receive(:postgres_paradedb_notification_email).and_return("dummy@mail.com")
        expect(Util).to receive(:send_email)

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-no-ha", {
          size: "standard-2",
          storage_size: "64",
          flavor: "paradedb"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "fails if invalid flavor is used" do
        project.set_ff_postgres_lantern(false)
        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-invalid", {
          size: "standard-2",
          storage_size: "64",
          flavor: "invalid"
        }.to_json
        expect(last_response.status).to eq(400)
      end

      it "fails if lantern feature flag is not enabled" do
        project.set_ff_postgres_lantern(false)
        post "/project/#{project.ubid}/location/eu-central-h1/postgres/test-postgres-lantern", {
          size: "standard-2",
          storage_size: "64",
          flavor: "lantern"
        }.to_json
        expect(last_response.status).to eq(400)
      end

      it "invalid location" do
        post "/project/#{project.ubid}/location/eu-north-h1/postgres/test-postgres", {
          size: "standard-2",
          storage_size: "64",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: location", {"location" => "Invalid location. Available options: eu-central-h1, us-east-a2, us-east-1, us-west-2"})
      end

      it "location not exist" do
        post "/project/#{project.ubid}/location/not-exist-location/postgres/test-postgres", {
          size: "standard-2",
          storage_size: "64",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(404, "Validation failed for following path components: location")
      end

      it "invalid size" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/test-postgres", {
          size: "invalid-size",
          storage_size: "64"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: size", {"size" => "Invalid size."})
      end

      it "invalid config values" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/test-postgres", {
          size: "standard-2",
          storage_size: "64",
          pg_config: {"wal_level" => "invalid"}
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: pg_config.wal_level")
      end

      it "valid config values" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/test-postgres", {
          size: "standard-2",
          storage_size: "64",
          pg_config: {"wal_level" => "logical"}
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "can set and update tags" do
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/test-postgres", {
          size: "standard-2",
          storage_size: "64",
          ha_type: "sync",
          tags: [{key: "env", value: "test"}, {key: "team", value: "devops"}]
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["tags"]).to eq([{"key" => "env", "value" => "test"}, {"key" => "team", "value" => "devops"}])

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/test-postgres", {
          tags: [{key: "env", value: "prod"}, {key: "team", value: "devops"}]
        }.to_json

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["tags"]).to eq([{"key" => "env", "value" => "prod"}, {"key" => "team", "value" => "devops"}])
      end

      it "can update database properties" do
        pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 128, disk_index: 0)

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
        pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 128, disk_index: 0)
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(PostgresResource.dataset.class, first: pg, association_join: instance_double(Sequel::Dataset, sum: 1))).twice
        expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project)
        expect(pg.representative_server.vm.sshable).to receive(:_cmd).and_return("10000000\n")

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}", {
          storage_size: 64
        }.to_json

        expect(pg.reload.target_storage_size_gib).to eq(64)
      end

      it "does not scale down storage if the requested size is too small for existing data" do
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project)
        expect(pg.representative_server).to receive(:storage_size_gib).and_return(128)
        expect(pg.representative_server.vm.sshable).to receive(:_cmd).and_return("999999999\n")

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}", {
          storage_size: 64
        }.to_json

        expect(pg.reload.target_storage_size_gib).to eq(128)
        expect(last_response).to have_api_error(400, "Validation failed for following fields: storage_size", {"storage_size" => "Insufficient storage size is requested. It is only possible to reduce the storage size if the current usage is less than 80% of the requested size."})
      end

      it "returns error message if current usage is unknown" do
        pg.representative_server.vm.add_vm_storage_volume(boot: false, size_gib: 128, disk_index: 0)

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}", {
          size: "standard-3"
        }.to_json

        expect(pg.reload.target_vm_size).to eq("standard-2")
        expect(last_response).to have_api_error(400, "Validation failed for following fields: size")
      end

      it "returns error message if invalid size is requested" do
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project)
        expect(pg.representative_server).to receive(:storage_size_gib).and_return(128)
        expect(pg.representative_server.vm.sshable).to receive(:_cmd).and_raise(StandardError.new("error"))

        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}", {
          storage_size: 64
        }.to_json

        expect(pg.reload.target_storage_size_gib).to eq(128)
        expect(last_response).to have_api_error(400, "Database is not ready for update")
      end

      it "read-replica" do
        expect(PostgresTimeline).to receive(:earliest_restore_time).and_return(true)

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/#{pg.name}/read-replica", {
          name: "my-read-replica"
        }.to_json

        expect(last_response.status).to eq(200)
      end

      it "fails read-replica creation if timeline doesn't have a backup yet" do
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project)
        expect(project).to receive(:quota_available?).and_return(true)
        expect(pg.timeline).to receive(:earliest_restore_time).and_return(nil)

        post "/project/#{project.ubid}/location/eu-central-h1/postgres/#{pg.name}/read-replica", {
          name: "my-read-replica"
        }.to_json

        expect(last_response).to have_api_error(400, "Parent server is not ready for read replicas. There are no backups, yet.")
      end

      it "promote" do
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project)
        pg.update(parent_id: pg.id)
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/promote"

        expect(last_response.status).to eq(200)
      end

      it "fails to promote if not read_replica" do
        expect(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
        expect(described_class).to receive(:authorized_project).with(user, project.id).and_return(project)

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

      it "firewall-rule edit" do
        fwr = pg.pg_firewall_rules.first
        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/#{fwr.ubid}", {
          cidr: "0.0.0.0/1",
          description: "Updated rule"
        }.to_json

        expect(fwr.reload.cidr.to_s).to eq("0.0.0.0/1")
        expect(last_response.status).to eq(200)
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
        expect(MinioCluster).to receive(:first).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
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
        pg.update(parent_id: "cde85384-4cf1-8ad0-aeb0-639f2ad94870")

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/reset-superuser-password", {
          password: "DummyPassword123"
        }.to_json

        expect(last_response).to have_api_error(400, "Superuser password cannot be updated for read replicas!")
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

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/set-maintenance-window", {
          maintenance_window_start_at: -2
        }.to_json

        expect(last_response.status).to eq(400)
        expect(pg.reload.maintenance_window_start_at).to be_nil
      end

      it "invalid payment" do
        expect(Config).to receive(:stripe_secret_key).and_return("secret_key")

        post "/project/#{project.ubid}/location/#{TEST_LOCATION}/postgres/test-postgres", {
          size: "standard-2",
          storage_size: "64",
          ha_type: "sync"
        }.to_json

        expect(last_response).to have_api_error(400, "Validation failed for following fields: billing_info")
      end
    end

    describe "metrics" do
      let(:prj) { Project.create_with_id("1d7edb2f-c1b8-4d28-b7a6-4226b5855e7d", name: "vm-project") }
      let(:vmr) { instance_double(VictoriaMetricsResource, project_id: prj.id) }
      let(:vm_server) { instance_double(VictoriaMetricsServer, client: tsdb_client) }
      let(:tsdb_client) { instance_double(VictoriaMetrics::Client) }

      before do
        allow(Config).to receive(:postgres_service_project_id).and_return(prj.id)
        allow(VictoriaMetricsResource).to receive(:first).with(project_id: prj.id).and_return(vmr)
        allow(vmr).to receive(:servers_dataset).and_return([vm_server])
        allow(VictoriaMetricsResource).to receive(:client_for_project).and_return(tsdb_client)
        allow(project).to receive(:postgres_resources_dataset).and_return(instance_double(Sequel::Dataset, first: pg))
      end

      it "returns metrics for the specified time range" do
        query_result = [
          {
            "values" => [[1619712000, "10.5"], [1619715600, "12.3"]],
            "labels" => {"instance" => "test-instance"}
          }
        ]

        expect(tsdb_client).to receive(:query_range).and_return(query_result)
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics?key=cpu_usage"

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["metrics"].first["name"]).to eq("CPU Usage")
        expect(response_body["metrics"].first["series"]).to be_an(Array)
      end

      it "returns all metrics when no name is specified" do
        query_result = [
          {
            "values" => [[1619712000, "10.5"], [1619715600, "12.3"]],
            "labels" => {"instance" => "test-instance"}
          }
        ]

        num_time_series = Metrics::POSTGRES_METRICS.values.sum { |metric| metric.series.count }

        expect(tsdb_client).to receive(:query_range).exactly(num_time_series).times.and_return(query_result)
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics"

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["metrics"].size).to eq(Metrics::POSTGRES_METRICS.size)
      end

      it "fails when end timestamp is before start timestamp" do
        query_params = {
          start: (DateTime.now.new_offset(0) - 1).rfc3339,
          end: (DateTime.now.new_offset(0) - 2).rfc3339
        }

        query_str = URI.encode_www_form(query_params)
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics?#{query_str}"
        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("End timestamp must be greater than start timestamp")
      end

      it "fails when time range is too large" do
        query_params = {
          start: (DateTime.now.new_offset(0) - 32).rfc3339,
          end: DateTime.now.new_offset(0).rfc3339
        }
        query_str = URI.encode_www_form(query_params)

        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics?#{query_str}"
        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Maximum time range is 31 days")
      end

      it "fails when start timestamp is too old" do
        query_params = {
          start: (DateTime.now.new_offset(0) - 32).rfc3339,
          end: (DateTime.now.new_offset(0) - 31).rfc3339
        }
        query_str = URI.encode_www_form(query_params)

        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics?#{query_str}"
        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Cannot query metrics older than 31 days")
      end

      it "fails when metric name is invalid" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics?key=invalid_metric"

        expect(last_response.status).to eq(400)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Invalid metric name")
      end

      it "returns 404 when victoria_metrics client is not available" do
        expect(PostgresServer).to receive(:victoria_metrics_client).and_return(nil)
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics"

        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Metrics are not configured for this instance")
      end

      it "uses local victoria-metrics client in development mode" do
        allow(Config).to receive(:development?).and_return(true)
        allow(VictoriaMetricsResource).to receive(:first).with(project_id: prj.id).and_return(nil)
        allow(VictoriaMetrics::Client).to receive(:new).and_return(tsdb_client)
        expect(tsdb_client).to receive(:query_range).at_least(:once).and_return([])
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics"
        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["metrics"]).not_to be_empty
      end

      it "handles empty metrics data properly" do
        expect(tsdb_client).to receive(:query_range).and_return([])
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics?key=cpu_usage"

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["metrics"].first["series"]).to be_empty
      end

      it "handles client errors gracefully for multi-metric queries" do
        expect(tsdb_client).to receive(:query_range).at_least(:once).and_raise(VictoriaMetrics::ClientError.new("Test error"))
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["metrics"]).to be_an(Array)
      end

      it "returns error for client errors with single metric queries" do
        expect(tsdb_client).to receive(:query_range).and_raise(VictoriaMetrics::ClientError.new("Test error"))
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/metrics?key=cpu_usage"

        expect(last_response.status).to eq(500)
        expect(JSON.parse(last_response.body)["error"]["message"]).to eq("Internal error while querying metrics")
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

      it "not found with valid looking but invalid ubid" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/pgg54eqqv6q26kgqrszmkypn7g"

        expect(last_response).to have_api_error(404, "Sorry, we couldn’t find the resource you’re looking for.")
      end

      it "returns error for firewall rules if customer firewall was deleted or detached" do
        pg.customer_firewall.remove_all_private_subnets
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/firewall-rule"

        expect(last_response).to have_api_error(400, "PostgreSQL firewall was deleted, manage firewall rules using an appropriate firewall on the #{pg.ubid}-subnet private subnet (id: #{pg.private_subnet.ubid})")
      end

      it "show firewall" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/firewall-rule"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"][0]["cidr"]).to eq("0.0.0.0/0")
        expect(JSON.parse(last_response.body)["items"][1]["cidr"]).to eq("0.0.0.0/0")
        expect(JSON.parse(last_response.body)["items"][2]["cidr"]).to eq("::/0")
        expect(JSON.parse(last_response.body)["items"][3]["cidr"]).to eq("::/0")
        expect(JSON.parse(last_response.body)["items"][0]["port"]).to eq 5432
        expect(JSON.parse(last_response.body)["items"][1]["port"]).to eq 6432
        expect(JSON.parse(last_response.body)["items"][2]["port"]).to eq 5432
        expect(JSON.parse(last_response.body)["items"][3]["port"]).to eq 6432
        expect(JSON.parse(last_response.body)["items"][0]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["items"][1]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["items"][2]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["items"][3]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["count"]).to eq(4)
      end

      it "does not include firewall rules for port ranges other than only 5432 or only 6432" do
        pg.customer_firewall.add_firewall_rule(cidr: "1.2.3.4/32", port_range: 22..22)
        pg.customer_firewall.add_firewall_rule(cidr: "2.2.3.4/32", port_range: 5432..6432)
        pg.customer_firewall.add_firewall_rule(cidr: "3.2.3.4/32", port_range: 6432..16432)
        pg.customer_firewall.add_firewall_rule(cidr: "4.2.3.4/32", port_range: 5432..5432, description: "my-host")
        pg.customer_firewall.add_firewall_rule(cidr: "5.2.3.4/32", port_range: 6432..6432)
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/firewall-rule"

        expect(last_response.status).to eq(200)
        expect(JSON.parse(last_response.body)["items"][0]["cidr"]).to eq("0.0.0.0/0")
        expect(JSON.parse(last_response.body)["items"][1]["cidr"]).to eq("0.0.0.0/0")
        expect(JSON.parse(last_response.body)["items"][2]["cidr"]).to eq("4.2.3.4/32")
        expect(JSON.parse(last_response.body)["items"][3]["cidr"]).to eq("5.2.3.4/32")
        expect(JSON.parse(last_response.body)["items"][4]["cidr"]).to eq("::/0")
        expect(JSON.parse(last_response.body)["items"][5]["cidr"]).to eq("::/0")
        expect(JSON.parse(last_response.body)["items"][0]["port"]).to eq 5432
        expect(JSON.parse(last_response.body)["items"][1]["port"]).to eq 6432
        expect(JSON.parse(last_response.body)["items"][2]["port"]).to eq 5432
        expect(JSON.parse(last_response.body)["items"][3]["port"]).to eq 6432
        expect(JSON.parse(last_response.body)["items"][4]["port"]).to eq 5432
        expect(JSON.parse(last_response.body)["items"][5]["port"]).to eq 6432
        expect(JSON.parse(last_response.body)["items"][0]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["items"][1]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["items"][2]["description"]).to eq("my-host")
        expect(JSON.parse(last_response.body)["items"][3]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["items"][4]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["items"][5]["description"]).to eq("")
        expect(JSON.parse(last_response.body)["count"]).to eq(6)
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
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/#{pg.pg_firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule ubid" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/firewall-rule/#{pg.pg_firewall_rules.first.ubid}"

        expect(last_response.status).to eq(204)
      end

      it "firewall-rule not exist" do
        delete "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/firewall-rule/fr000000000000000000000000"

        expect(last_response.status).to eq(204)
      end

      it "metric-destination" do
        PostgresMetricDestination.create(
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

    describe "config" do
      it "read" do
        pg.update(user_config: {"max_connections" => "100"}, pgbouncer_user_config: {"max_client_conn" => "100"})

        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/config"

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["pg_config"]).to eq({"max_connections" => "100"})
        expect(response_body["pgbouncer_config"]).to eq({"max_client_conn" => "100"})
      end

      it "full update" do
        pg.update(user_config: {"max_connections" => "100"}, pgbouncer_user_config: {"max_client_conn" => "100"})
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/config", {
          pg_config: {"archive_mode" => "on"},
          pgbouncer_config: {"admin_users" => "postgres"}
        }.to_json

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["pg_config"]).to eq({"archive_mode" => "on"})
        expect(response_body["pgbouncer_config"]).to eq({"admin_users" => "postgres"})

        expect(pg.reload.user_config).to eq({"archive_mode" => "on"})
        expect(pg.reload.pgbouncer_user_config).to eq({"admin_users" => "postgres"})
      end

      it "partial update" do
        pg.update(user_config: {"max_connections" => "100", "default_transaction_isolation" => "serializable", "archive_mode" => "on"}, pgbouncer_user_config: {"max_client_conn" => "100", "pool_mode" => "session"})
        patch "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/config", {
          pg_config: {"archive_mode" => "on", "max_connections" => "120", "default_transaction_isolation" => nil},
          pgbouncer_config: {"admin_users" => "postgres", "pool_mode" => nil}
        }.to_json

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["pg_config"]).to eq({"max_connections" => "120", "archive_mode" => "on"})
        expect(response_body["pgbouncer_config"]).to eq({"max_client_conn" => "100", "admin_users" => "postgres"})

        expect(pg.reload.user_config).to eq({"max_connections" => "120", "archive_mode" => "on"})
        expect(pg.reload.pgbouncer_user_config).to eq({"max_client_conn" => "100", "admin_users" => "postgres"})
      end
    end

    describe "upgrade" do
      before do
        VmStorageVolume.create(vm_id: pg.representative_server.vm.id, size_gib: pg.target_storage_size_gib, boot: false, disk_index: 0)
        allow(pg.representative_server).to receive(:version).and_return("16")
      end

      it "success post" do
        old_pg_version = pg.version.to_i
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/upgrade"

        expect(last_response.status).to eq(200)
        response = JSON.parse(last_response.body)
        expect(response["upgrade_status"]).to eq("running")
        expect(response["current_version"]).to eq(pg.version)
        expect(response["target_version"]).to eq(pg.reload.target_version)
        expect(pg.reload.target_version.to_i).to eq(old_pg_version + 1)
      end

      it "failed post" do
        old_pg_version = pg.version.to_i
        pg.update(target_storage_size_gib: 256)
        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/upgrade"

        expect(last_response.status).to eq(400)
        expect(pg.reload.version.to_i).to eq(old_pg_version)
      end

      it "success get" do
        old_pg_version = pg.version.to_i

        post "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/upgrade"
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/upgrade"

        expect(last_response.status).to eq(200)
        response = JSON.parse(last_response.body)
        expect(response["upgrade_status"]).to eq("running")
        expect(response["current_version"]).to eq(pg.version)
        expect(response["target_version"]).to eq(pg.reload.target_version)
        expect(pg.reload.target_version.to_i).to eq(old_pg_version + 1)
      end

      it "no ongoing upgrade" do
        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/upgrade"

        expect(last_response.status).to eq(400)
      end
    end

    describe "backup" do
      it "returns backups successfully" do
        backup = Struct.new(:key, :last_modified)
        backup_time = Time.now.utc
        expect(MinioCluster).to receive(:first).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
        expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, list_objects: [
          backup.new("basebackups_005/backup1_backup_stop_sentinel.json", backup_time - 2 * 24 * 60 * 60),
          backup.new("basebackups_005/backup2_backup_stop_sentinel.json", backup_time - 1 * 24 * 60 * 60)
        ])).at_least(:once)

        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/backup"

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["count"]).to eq(2)
        expect(response_body["items"].length).to eq(2)
        expect(response_body["items"][0]["key"]).to eq("basebackups_005/backup1_backup_stop_sentinel.json")
        expect(response_body["items"][1]["key"]).to eq("basebackups_005/backup2_backup_stop_sentinel.json")
      end

      it "returns empty list when no backups exist" do
        expect(MinioCluster).to receive(:first).and_return(instance_double(MinioCluster, url: "dummy-url", root_certs: "dummy-certs")).at_least(:once)
        expect(Minio::Client).to receive(:new).and_return(instance_double(Minio::Client, list_objects: [])).at_least(:once)

        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.ubid}/backup"

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["count"]).to eq(0)
        expect(response_body["items"]).to eq([])
      end

      it "returns empty list when blob storage is not configured" do
        expect(MinioCluster).to receive(:first).and_return(nil).at_least(:once)

        get "/project/#{project.ubid}/location/#{pg.display_location}/postgres/#{pg.name}/backup"

        expect(last_response.status).to eq(200)
        response_body = JSON.parse(last_response.body)
        expect(response_body["count"]).to eq(0)
        expect(response_body["items"]).to eq([])
      end
    end
  end
end
