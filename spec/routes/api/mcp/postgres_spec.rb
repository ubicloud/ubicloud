# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Clover, "mcp postgres tools" do
  let(:forbidden) { "Forbidden: Sorry, you don't have permission to continue with this request." }

  describe "get_postgres_options" do
    let(:capabilities) do
      get "/project/#{@project.ubid}/postgres/capabilities"
      JSON.parse(last_response.body)
    end

    it "returns only the metadata without a location" do
      data = mcp_tool_data("get_postgres_options")
      expect(data).to eq("metadata" => capabilities["metadata"])
      expect(data.dig("metadata", "location", "hetzner-fsn1")).to eq("display_name" => "eu-central-h1", "ui_name" => "Germany", "provider" => "hetzner")
    end

    it "prunes the option tree to one location given by display name" do
      data = mcp_tool_data("get_postgres_options", location: "eu-central-h1")
      standard = capabilities.dig("option_tree", "flavor", "standard")
      expect(data).to eq(
        "metadata" => capabilities["metadata"],
        "option_tree" => {"standard" => {"version" => standard["version"], "location" => {"eu-central-h1" => standard.dig("location", "hetzner-fsn1")}}},
      )
      expect(data.dig("option_tree", "standard", "location", "eu-central-h1", "family")).to have_key("standard")
    end

    it "omits flavors that are not offered in the location" do
      @project.set_ff_postgres_lantern(true)
      expect(mcp_tool_data("get_postgres_options", location: "eu-central-h1")["option_tree"].keys).to eq ["standard", "lantern"]
      expect(mcp_tool_data("get_postgres_options", location: "us-east-1")["option_tree"].keys).to eq ["standard"]
    end

    it "lists the display names of the locations that offer PostgreSQL for any other location" do
      ["eu-north-h1", "hetzner-fsn1", "Germany", "nowhere", "eu-central-h1/x", "eu-central-h1\nx"].each do |location|
        expect(mcp_tool_error("get_postgres_options", location:)).to eq "InvalidRequest: location must be the display name of a location that offers PostgreSQL for this project: eu-central-h1, us-east-1, us-east-a2, us-west-2"
      end
    end

    it "works with a token restricted to Postgres:view" do
      restrict_pat_to("Postgres:view")
      expect(mcp_tool_data("get_postgres_options")).to have_key("metadata")
    end

    it "returns Forbidden when the token lacks the view permission" do
      restrict_pat_to("Project:view")
      expect(mcp_tool_error("get_postgres_options")).to eq forbidden
    end
  end

  context "with a database" do
    def create_pg(name, **)
      Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: @project.id,
        location_id: Location::HETZNER_FSN1_ID,
        name:,
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
        **,
      ).subject
    end

    let(:summary) do
      {
        "id" => @pg.ubid,
        "name" => "test-pg",
        "state" => "creating",
        "location" => "eu-central-h1",
        "vm_size" => "standard-2",
        "target_vm_size" => "standard-2",
        "storage_size_gib" => 64,
        "target_storage_size_gib" => 64,
        "target_version" => "18",
        "version" => "18",
        "ha_type" => "none",
        "target_server_count" => 1,
        "flavor" => "standard",
        "maintenance_window_start_at" => nil,
        "read_replica" => false,
        "parent" => nil,
        "fallback_active" => false,
        "tags" => [],
        "created_at" => @pg.created_at.iso8601,
      }
    end

    before do
      expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
      @pg = create_pg("test-pg")
    end

    describe "list_postgres" do
      it "lists databases without their CA certificates" do
        @pg.update(root_cert_1: "a", root_cert_2: "b")
        expect(mcp_tool_data("list_postgres")).to eq("items" => [summary], "count" => 1, "next_cursor" => nil)
      end

      it "works with a token restricted to Postgres:view" do
        restrict_pat_to("Postgres:view")
        expect(mcp_tool_data("list_postgres")["items"]).to eq [summary]
      end

      it "returns an empty list when the token lacks the view permission" do
        restrict_pat_to("Project:view")
        expect(mcp_tool_data("list_postgres")).to eq("items" => [], "count" => 0, "next_cursor" => nil)
      end

      it "restricts to one location" do
        expect(mcp_tool_data("list_postgres", location: "eu-central-h1")["items"]).to eq [summary]
        expect(mcp_tool_data("list_postgres", location: "eu-north-h1")).to eq("items" => [], "count" => 0, "next_cursor" => nil)
      end

      it "returns InvalidLocation for an unknown location" do
        expect(mcp_tool_error("list_postgres", location: "nowhere")).to start_with "InvalidLocation: "
      end

      it "rejects a location that is not a display name" do
        ["eu-central-h1/vm/x/serial-log?x", "eu-central-h1/postgres/test-pg/servers?\nx", "EU Central"].each do |location|
          expect(mcp_tool_error("list_postgres", location:)).to eq "InvalidRequest: location must be a display name such as eu-central-h1"
        end
      end

      it "filters by tags" do
        @pg.update(tags: [{key: "env", value: "prod"}])
        create_pg("other-pg")
        data = mcp_tool_data("list_postgres", tags: "env:prod")
        expect(data["items"].map { [it["name"], it["tags"]] }).to eq [["test-pg", [{"key" => "env", "value" => "prod"}]]]
        expect(data["count"]).to eq 1
      end

      it "passes tag format errors through" do
        expect(mcp_tool_error("list_postgres", tags: "env")).to eq "InvalidRequest: Validation failed for following fields: tags; tags: Invalid tag format. Expected format: key:value"
      end

      it "rejects tags combined with a location" do
        expect(mcp_tool_error("list_postgres", location: "eu-central-h1", tags: "env:prod")).to eq "InvalidRequest: tags cannot be combined with location"
      end

      it "treats blank tags as no tags, as the API does" do
        expect(mcp_tool_data("list_postgres", location: "eu-central-h1", tags: " ")["items"]).to eq [summary]
      end

      it "pages in id order" do
        first, second = [@pg, create_pg("other-pg")].sort_by(&:id)

        page = mcp_tool_data("list_postgres", limit: 1)
        expect(page["items"].map { it["id"] }).to eq [first.ubid]
        expect(page["count"]).to eq 2
        expect(page["next_cursor"]).to eq first.ubid

        page = mcp_tool_data("list_postgres", limit: 2, cursor: page["next_cursor"])
        expect(page["items"].map { it["id"] }).to eq [second.ubid]
        expect(page["next_cursor"]).to be_nil
      end
    end

    describe "get_postgres" do
      let(:server) { @pg.representative_server }

      it "returns details without secrets and with reduced nested rows" do
        expect(Config).to receive(:postgres_service_hostname_v3).and_return("pg.example.com").at_least(:once)
        DnsZone.create(project_id: @project.id, name: "pg.example.com")
        @pg.update(root_cert_1: "a", root_cert_2: "b")
        metric_destination = @pg.add_metric_destination(username: "md-user", password: "1", url: "https://md.example.com")
        @pg.add_log_destination(name: "ld-name", type: "syslog", url: "tcp://logs.example.com:6514")
        replica = create_pg("test-pg-rr", parent_id: @pg.id)

        result = mcp_tool("get_postgres", ref: "eu-central-h1/test-pg")
        expect(result["isError"]).to be false
        expect(result.dig("content", 0, "text")).not_to include @pg.superuser_password
        data = result["structuredContent"]
        expect(JSON.parse(result.dig("content", 0, "text"))).to eq data
        expect(data.keys & %w[password connection_string private_connection_string ca_certificates]).to be_empty
        expect(data).to match(summary.merge(
          "username" => "postgres",
          "hostname" => "test-pg.#{@pg.ubid}.pg.example.com",
          "primary" => true,
          "firewall_rules" => @pg.pg_firewall_rules.map { {"id" => it.ubid, "cidr" => it.cidr.to_s, "port" => it.port_range.begin, "description" => ""} },
          "metric_destinations" => [{"id" => metric_destination.ubid, "host" => "md.example.com"}],
          "read_replicas" => [{"id" => replica.ubid, "name" => "test-pg-rr", "location" => "eu-central-h1", "state" => "creating"}],
          "log_destinations" => [{"name" => "ld-name", "type" => "syslog"}],
          "earliest_restore_time" => nil,
          "latest_restore_time" => a_string_matching(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/),
          "servers" => [{"id" => server.ubid, "role" => "primary", "state" => "creating", "synchronization_status" => "ready", "vm_size" => "standard-2", "fallback_active" => false}],
          "converged" => false,
          "pending" => ["state: creating", "server #{server.ubid}: creating"],
        ))
      end

      it "returns no part of a metric destination URL but its host" do
        post "/project/#{@project.ubid}/location/eu-central-h1/postgres/test-pg/metric-destination", {
          url: "https://md-user:md-secret@md.example.com:8443/md-path?api_key=md-key#md-fragment",
          username: "md-basic-user",
          password: "md-basic-password",
        }.to_json
        expect(last_response.status).to eq 200

        result = mcp_tool("get_postgres", ref: @pg.ubid)
        expect(result.dig("structuredContent", "metric_destinations")).to eq [{"id" => @pg.metric_destinations.first.ubid, "host" => "md.example.com"}]
        text = result.dig("content", 0, "text")
        %w[md-user md-secret 8443 md-path md-key md-fragment md-basic].each { expect(text).not_to include it }
      end

      it "works with a token restricted to Postgres:view" do
        restrict_pat_to("Postgres:view")
        expect(mcp_tool_data("get_postgres", ref: @pg.ubid)).to include("id" => @pg.ubid, "converged" => false)
      end

      context "when the database and its servers are running" do
        before do
          @pg.strand.update(label: "wait")
          server.strand.update(label: "wait")
        end

        def pending_changes
          data = mcp_tool_data("get_postgres", ref: @pg.ubid)
          expect(data["converged"]).to be false
          data["pending"]
        end

        it "is converged" do
          data = mcp_tool_data("get_postgres", ref: @pg.ubid)
          expect(data).to include("state" => "running", "converged" => true, "pending" => [])
          expect(data).not_to have_key("upgrade")
        end

        it "reports a resize" do
          @pg.update(target_vm_size: "standard-4")
          expect(pending_changes).to eq ["vm_size: standard-2 -> standard-4"]
        end

        it "reports a storage change" do
          @pg.update(target_storage_size_gib: 128)
          expect(pending_changes).to eq ["storage_size_gib: 64 -> 128"]
        end

        it "reports an HA change" do
          @pg.update(ha_type: "async")
          expect(pending_changes).to eq ["servers: 1 of 2"]
        end

        it "reports a restart" do
          server.incr_restart
          expect(pending_changes).to eq ["state: restarting", "server #{server.ubid}: restarting"]
        end

        it "reports a version upgrade with its status" do
          server.update(version: "17")
          data = mcp_tool_data("get_postgres", ref: @pg.ubid)
          expect(data).to include("converged" => false, "pending" => ["version: 17 -> 18"], "upgrade" => {"status" => "running", "stage" => nil})
        end

        it "reports a failed upgrade" do
          server.update(version: "17")
          Strand.create(parent_id: @pg.strand.id, prog: "Postgres::ConvergePostgresResource", label: "upgrade_failed")
          data = mcp_tool_data("get_postgres", ref: @pg.ubid)
          expect(data).to include("converged" => false, "pending" => ["version: 17 -> 18"], "upgrade" => {"status" => "failed", "stage" => "upgrade_failed"})
        end

        it "reports a recycle request" do
          post "/project/#{@project.ubid}/location/eu-central-h1/postgres/test-pg/recycle"
          expect(last_response.status).to eq 200
          expect(pending_changes).to eq ["servers: replacement pending"]
        end

        it "reports a recycle request during a restart" do
          server.incr_restart
          post "/project/#{@project.ubid}/location/eu-central-h1/postgres/test-pg/recycle"
          expect(last_response.status).to eq 200
          expect(pending_changes).to eq ["servers: replacement pending", "state: restarting", "server #{server.ubid}: restarting"]
        end

        it "ignores the size difference of a fallback instance type" do
          @pg.update(target_vm_size: "standard-4")
          server.incr_ignore_instance_size_mismatch
          data = mcp_tool_data("get_postgres", ref: @pg.ubid)
          expect(data).to include("vm_size" => "standard-2", "target_vm_size" => "standard-4", "fallback_active" => true, "converged" => true, "pending" => [])
        end

        describe "when the state changes between the inner requests" do
          def get_postgres_changing_before_upgrade_request
            server.update(version: "17")
            expect(described_class).to receive(:call).exactly(3).times.and_wrap_original do |call, env|
              yield if env["PATH_INFO"].end_with?("/upgrade")
              call.call(env)
            end
            mcp_tool("get_postgres", ref: "eu-central-h1/test-pg")
          end

          it "treats an upgrade that finished as no upgrade" do
            data = get_postgres_changing_before_upgrade_request { server.update(version: "18") }.fetch("structuredContent")
            expect(data).to include("version" => "17", "converged" => false, "pending" => ["version: 17 -> 18"])
            expect(data).not_to have_key("upgrade")
          end

          it "fails when the upgrade request fails for another reason" do
            result = get_postgres_changing_before_upgrade_request { @pg.update(name: "renamed-pg") }
            expect(result["isError"]).to be true
            expect(result.dig("content", 0, "text")).to start_with "ResourceNotFound: "
          end
        end
      end
    end

    describe "get_postgres_config" do
      before do
        @pg.update(user_config: {"shared_buffers" => "1GB"}, pgbouncer_user_config: {"max_client_conn" => "100"})
      end

      it "returns the overrides" do
        expect(mcp_tool_data("get_postgres_config", ref: "eu-central-h1/test-pg")).to eq("pg_config" => {"shared_buffers" => "1GB"}, "pgbouncer_config" => {"max_client_conn" => "100"})
      end

      it "looks up keys in the overrides and the defaults" do
        expect(mcp_tool_data("get_postgres_config", ref: @pg.ubid, keys: ["shared_buffers", "work_mem", "max_client_conn"])).to eq(
          "pg_config" => {"shared_buffers" => "1GB"},
          "pgbouncer_config" => {"max_client_conn" => "100"},
          "default_pg_config" => {"shared_buffers" => "2048MB", "work_mem" => "1MB"},
        )
      end

      it "returns the defaults once when given keys and include_defaults" do
        expect(mcp_tool_data("get_postgres_config", ref: @pg.ubid, keys: ["shared_buffers"], include_defaults: true)).to eq(
          "pg_config" => {"shared_buffers" => "1GB"},
          "pgbouncer_config" => {},
          "default_pg_config" => {"shared_buffers" => "2048MB"},
        )
      end

      it "includes the full default configuration on request" do
        data = mcp_tool_data("get_postgres_config", ref: @pg.ubid, include_defaults: true)
        expect(data.keys).to eq ["pg_config", "pgbouncer_config", "default_pg_config"]
        expect(data["default_pg_config"]).to include("shared_buffers" => "2048MB", "work_mem" => "1MB", "max_connections" => "500")
      end

      it "works with a token restricted to Postgres:view" do
        restrict_pat_to("Postgres:view")
        expect(mcp_tool_data("get_postgres_config", ref: @pg.ubid)["pg_config"]).to eq("shared_buffers" => "1GB")
      end
    end

    describe "list_postgres_backups" do
      it "returns the count, the oldest backup and the newest backups first" do
        create_minio_cluster_for_blob_storage
        backup = Struct.new(:key, :last_modified)
        now = Time.now.utc
        backups = [3, 1, 2].map { backup.new("basebackups_005/backup#{it}_backup_stop_sentinel.json", now - it * 24 * 60 * 60) }
        minio = instance_double(Minio::Client)
        expect(minio).to receive(:list_objects).with(@pg.timeline.ubid, "basebackups_005/", delimiter: "/").twice.and_return(backups)
        expect(Minio::Client).to receive(:new).and_return(minio).twice
        row = ->(n) { {"key" => "basebackups_005/backup#{n}_backup_stop_sentinel.json", "last_modified" => (now - n * 24 * 60 * 60).iso8601} }

        expect(mcp_tool_data("list_postgres_backups", ref: "eu-central-h1/test-pg")).to eq("count" => 3, "oldest" => row[3], "newest" => [row[1], row[2], row[3]])
        expect(mcp_tool_data("list_postgres_backups", ref: @pg.ubid, limit: 2)).to eq("count" => 3, "oldest" => row[3], "newest" => [row[1], row[2]])
      end

      it "returns an empty inventory without blob storage" do
        expect(mcp_tool_data("list_postgres_backups", ref: @pg.ubid)).to eq("count" => 0, "oldest" => nil, "newest" => [])
      end

      it "works with a token restricted to Postgres:view" do
        restrict_pat_to("Postgres:view")
        expect(mcp_tool_data("list_postgres_backups", ref: @pg.ubid)["count"]).to eq 0
      end
    end

    %w[get_postgres get_postgres_config list_postgres_backups].each do |tool|
      describe "#{tool} references" do
        it "returns Forbidden by name and ResourceNotFound by id when the token lacks the view permission" do
          restrict_pat_to("Project:view")
          expect(mcp_tool_error(tool, ref: "eu-central-h1/test-pg")).to eq forbidden
          expect(mcp_tool_error(tool, ref: @pg.ubid)).to start_with "ResourceNotFound: "
        end

        it "rejects a malformed ref and an id of another type" do
          expect(mcp_tool_error(tool, ref: "foo")).to eq "InvalidRequest: ref must be location/name or a pg... id"
          expect(mcp_tool_error(tool, ref: "vm345678901234567890123456")).to eq "InvalidRequest: ref must be location/name or a pg... id"
        end

        it "rejects a ref that would end the path early" do
          expect(mcp_tool_error(tool, ref: "eu-central-h1/test-pg?")).to eq "InvalidRequest: ref must be location/name or a pg... id"
        end

        it "returns ResourceNotFound for an unknown name or id" do
          expect(mcp_tool_error(tool, ref: "eu-central-h1/nope")).to start_with "ResourceNotFound: "
          expect(mcp_tool_error(tool, ref: "pg345678901234567890123456")).to start_with "ResourceNotFound: "
        end

        it "returns InvalidLocation for an unknown location" do
          expect(mcp_tool_error(tool, ref: "nowhere/test-pg")).to start_with "InvalidLocation: "
        end
      end
    end
  end
end
