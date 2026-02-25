# frozen_string_literal: true

require_relative "../../../prog/postgres/spec_helper"

RSpec.describe Prog::Postgres::PostgresServerNexus::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:nx) { Prog::Postgres::PostgresServerNexus.new(st) }

  let(:project) { Project.create(name: "test-project") }
  let(:postgres_resource) { create_postgres_resource(project:, location_id:) }
  let(:postgres_timeline) { create_postgres_timeline(location_id:) }
  let(:postgres_server) { create_postgres_server(resource: postgres_resource, timeline: postgres_timeline) }
  let(:st) { postgres_server.strand }
  let(:server) { nx.postgres_server }
  let(:sshable) { server.vm.sshable }
  let(:service_project) { Project.create(name: "postgres-service-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
  end

  describe "#setup_otel_collector" do
    it "writes otel config, enables and reloads otelcol-contrib, then hops to bootstrap_rhizome" do
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")
      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol")
      expect(sshable).to receive(:write_file).with("/var/lib/node_exporter/vm_sku.prom", match(/node_memory_sku_total_bytes/))
      expect(sshable).to receive(:_cmd).with("sudo systemctl enable --now otelcol-contrib")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")
      expect { nx.setup_otel_collector }.to hop("bootstrap_rhizome")
    end
  end

  describe "#setup_otel" do
    before do
      allow(sshable).to receive(:write_file).with("/var/lib/node_exporter/vm_sku.prom", match(/node_memory_sku_total_bytes/))
    end

    it "writes the SKU memory as a node exporter prom file" do
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")
      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol")
      expect(sshable).to receive(:write_file).with(
        "/var/lib/node_exporter/vm_sku.prom",
        match(/node_memory_sku_total_bytes #{postgres_server.sku_memory_bytes}/)
      )

      nx.setup_otel
    end

    it "writes otelcol config with metadata and export endpoint" do
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
        expect(content).to include("exporters:")
        expect(content).to include("endpoint: https://otel.example.com:4317")
        expect(content).to include("processors:")
        expect(content).to include("ubi.postgres_server_ubid")
        expect(content).to include("ubi.postgres_resource_ubid")
        expect(content).to include("ubi.postgres_resource_uuid")
        expect(content).to include("ubi.postgres_server_role")
        expect(content).to include("ubi.postgres_resource_read_replica")
        expect(content).to include("ubi.postgres_resource_ha_type")
        expect(content).to include("ubi.postgres_resource_target_standby_count")
        expect(content).to include("ubi.postgres_resource_target_server_count")
      end

      nx.setup_otel
    end

    it "writes otelcol config with empty endpoint when not configured" do
      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
        expect(content).to include("exporters:")
        expect(content).to include("endpoint:")
        expect(content).to include("processors:")
        expect(content).to include("ubi.postgres_server_ubid")
        expect(content).to include("ubi.postgres_resource_ubid")
        expect(content).to include("ubi.postgres_resource_uuid")
        expect(content).to include("ubi.postgres_resource_ha_type")
        expect(content).to include("ubi.postgres_resource_target_standby_count")
        expect(content).to include("ubi.postgres_resource_target_server_count")
      end

      nx.setup_otel
    end

    it "writes otelcol config with dynamic tag attributes" do
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

      postgres_server.resource.update(tags: [
        {"key" => "environment", "value" => "production"},
        {"key" => "team", "value" => "backend"}
      ])

      expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
        expect(content).to include("ubi.postgres_resource_tags_label_environment")
        expect(content).to include("value: 'production'")
        expect(content).to include("ubi.postgres_resource_tags_label_team")
        expect(content).to include("value: 'backend'")

        parsed = YAML.safe_load(content)
        attrs = parsed.dig("processors", "resource/ubiMetadata", "attributes")
        tag_keys = attrs.map { |a| a["key"] }
        expect(tag_keys).to include("ubi.postgres_resource_tags_label_environment")
        expect(tag_keys).to include("ubi.postgres_resource_tags_label_team")
      end

      nx.setup_otel
    end

    context "with OIDC authentication enabled" do
      let(:oidc_provider) {
        OidcProvider.create(
          display_name: "test-provider",
          url: "https://test-auth.example.com/",
          authorization_endpoint: "/authorize",
          token_endpoint: "/oauth/token",
          userinfo_endpoint: "/userinfo",
          jwks_uri: "https://test-auth.example.com/.well-known/jwks.json",
          client_id: "test-client-id",
          client_secret: "test-client-secret"
        )
      }

      before do
        allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(oidc_provider.id)
      end

      it "includes auth configuration in otel config" do
        postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

        expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
          expect(content).to include("auth:")
          expect(content).to include("authenticator: bearertokenauth/otlp-export")
        end

        expect(nx).to receive(:otel_token_needs_refresh?).and_return(false)

        nx.setup_otel
      end

      it "includes standby role in otel config for non-representative server" do
        server
        standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
        standby_nx = Prog::Postgres::PostgresServerNexus.new(standby.strand)
        standby_sshable = standby_nx.postgres_server.vm.sshable
        postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

        expect(standby_sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
          expect(content).to include("value: 'standby'")
        end
        expect(standby_sshable).to receive(:write_file).with("/var/lib/node_exporter/vm_sku.prom", match(/node_memory_sku_total_bytes/))

        expect(standby_nx).to receive(:otel_token_needs_refresh?).and_return(false)

        standby_nx.setup_otel
      end

      it "calls write_otel_token when token needs refresh" do
        postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

        expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol")
        expect(nx).to receive(:otel_token_needs_refresh?).and_return(true)
        expect(nx).to receive(:write_otel_token)

        nx.setup_otel
      end

      it "does not include auth configuration when OIDC provider is not configured" do
        allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(nil)
        postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")

        expect(sshable).to receive(:write_file).with("/home/otelcol/otel-config-override.yaml", anything, user: "otelcol") do |_, content, _|
          expect(content).not_to include("auth:")
          expect(content).not_to include("authenticator: bearertokenauth/otlp-export")
        end

        expect(nx).to receive(:otel_token_needs_refresh?).and_return(false)

        nx.setup_otel
      end
    end
  end

  describe "#write_otel_token" do
    let(:oidc_provider) {
      OidcProvider.create(
        display_name: "test-provider",
        url: "https://test-auth.example.com/",
        authorization_endpoint: "/authorize",
        token_endpoint: "/oauth/token",
        userinfo_endpoint: "/userinfo",
        jwks_uri: "https://test-auth.example.com/.well-known/jwks.json",
        client_id: "test-client-id",
        client_secret: "test-client-secret"
      )
    }

    before do
      allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(oidc_provider.id)
      postgres_server.resource.location.update(otel_otlp_export_endpoint: "https://otel.example.com:4317")
    end

    it "returns early when OIDC provider is not configured" do
      allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(nil)

      expect(Excon).not_to receive(:post)
      nx.write_otel_token
    end

    it "makes token request with correct parameters" do
      stub_request(:post, "https://test-auth.example.com/oauth/token")
        .with(
          body: hash_including(
            "grant_type" => "client_credentials",
            "audience" => "https://otel.example.com:4317"
          )
        )
        .to_return(
          status: 200,
          body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600})
        )

      expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

      nx.write_otel_token
    end

    it "reloads otelcol-contrib after writing the token" do
      stub_request(:post, "https://test-auth.example.com/oauth/token")
        .to_return(
          status: 200,
          body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600})
        )

      expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol").ordered
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib").ordered

      nx.write_otel_token
    end

    context "with additional metadata field configured" do
      before do
        allow(Config).to receive(:postgres_otel_otlp_export_additional_metadata_field).and_return("aws_client_metadata")
      end

      it "includes metadata in token request" do
        stub_request(:post, "https://test-auth.example.com/oauth/token")
          .with(
            body: hash_including("aws_client_metadata")
          )
          .to_return(
            status: 200,
            body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600})
          )

        expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
        expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

        nx.write_otel_token
      end

      it "includes correct metadata with server ubid, resource ubid, and role" do
        metadata_json = nil

        stub_request(:post, "https://test-auth.example.com/oauth/token")
          .with { |request|
            body_params = CGI.parse(request.body)
            metadata_json = JSON.parse(body_params["aws_client_metadata"].first) if body_params["aws_client_metadata"]
            true
          }
          .to_return(
            status: 200,
            body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600})
          )

        expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
        expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

        nx.write_otel_token

        expect(metadata_json).not_to be_nil
        expect(metadata_json["postgres_server_id"]).to eq(postgres_server.ubid)
        expect(metadata_json["postgres_resource_id"]).to eq(postgres_server.resource.ubid)
        expect(metadata_json["postgres_resource_uuid"]).to eq(postgres_server.resource.id)
        expect(metadata_json["postgres_server_role"]).to eq("primary")
      end

      it "includes standby role when server is not representative" do
        standby = create_postgres_server(resource: postgres_resource, timeline: postgres_timeline, is_representative: false)
        standby_nx = Prog::Postgres::PostgresServerNexus.new(standby.strand)
        standby_sshable = standby_nx.postgres_server.vm.sshable

        metadata_json = nil

        stub_request(:post, "https://test-auth.example.com/oauth/token")
          .with { |request|
            body_params = CGI.parse(request.body)
            metadata_json = JSON.parse(body_params["aws_client_metadata"].first) if body_params["aws_client_metadata"]
            true
          }
          .to_return(
            status: 200,
            body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer", "expires_in" => 3600})
          )

        expect(standby_sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
        expect(standby_sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

        standby_nx.write_otel_token

        expect(metadata_json).not_to be_nil
        expect(metadata_json["postgres_server_role"]).to eq("standby")
      end
    end

    it "raises error when OIDC provider ID is configured but provider does not exist" do
      non_existent_uuid = SecureRandom.uuid
      allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(non_existent_uuid)

      expect {
        nx.write_otel_token
      }.to raise_error(/does not correspond to an existing OidcProvider/)
    end

    it "raises error when OAuth response is missing access_token" do
      stub_request(:post, "https://test-auth.example.com/oauth/token")
        .to_return(
          status: 200,
          body: JSON.generate({"token_type" => "Bearer", "expires_in" => 3600})
        )

      expect {
        nx.write_otel_token
      }.to raise_error(/missing access_token/)
    end

    it "makes token request without audience when endpoint is not set" do
      postgres_server.resource.location.update(otel_otlp_export_endpoint: nil)

      stub_request(:post, "https://test-auth.example.com/oauth/token")
        .with { |request|
          params = CGI.parse(request.body)
          params["grant_type"] == ["client_credentials"] && !params.key?("audience")
        }
        .to_return(
          status: 200,
          body: JSON.generate({"access_token" => "test-token", "token_type" => "Bearer"})
        )

      expect(sshable).to receive(:write_file).with("/home/otelcol/otlp-export.token", "test-token", user: "otelcol")
      expect(sshable).to receive(:_cmd).with("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")

      nx.write_otel_token
    end
  end

  describe "#otel_token_needs_refresh?" do
    it "returns false when OIDC provider is not configured" do
      allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(nil)
      expect(nx.otel_token_needs_refresh?).to be false
    end

    context "when OIDC provider is configured" do
      before do
        allow(Config).to receive(:postgres_otel_otlp_export_jwt_oidc_provider_id).and_return(SecureRandom.uuid)
      end

      it "returns true when token file is missing" do
        expect(sshable).to receive(:_cmd).with(anything).and_return("missing\n")
        expect(nx.otel_token_needs_refresh?).to be true
      end

      it "returns true when token file is empty" do
        expect(sshable).to receive(:_cmd).with(anything).and_return("exists\n")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return("")
        expect(nx.otel_token_needs_refresh?).to be true
      end

      it "returns true when JWT is missing iat or exp claims" do
        token = JWT.encode({"sub" => "test"}, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything).and_return("exists\n")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(token)
        expect(nx.otel_token_needs_refresh?).to be true
      end

      it "returns false when token is still fresh" do
        now = Time.now.to_i
        token = JWT.encode({"iat" => now, "exp" => now + 3600}, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything).and_return("exists\n")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(token)
        expect(nx.otel_token_needs_refresh?).to be false
      end

      it "returns true when 2/3 of token validity has passed" do
        now = Time.now.to_i
        token = JWT.encode({"iat" => now - 3000, "exp" => now - 3000 + 3600}, nil, "none")
        expect(sshable).to receive(:_cmd).with(anything).and_return("exists\n")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return(token)
        expect(nx.otel_token_needs_refresh?).to be true
      end

      it "returns true on JWT decode error" do
        expect(sshable).to receive(:_cmd).with(anything).and_return("exists\n")
        expect(sshable).to receive(:_cmd).with(anything, log: false).and_return("not-a-valid-jwt")
        expect(nx.otel_token_needs_refresh?).to be true
      end
    end
  end
end
