# frozen_string_literal: true

require "excon"
require "jwt"

class Prog::Postgres::PostgresServerNexus
  label :setup_otel_collector

  module PrependMethods
    def setup_otel_collector
      register_deadline("bootstrap_rhizome", 2 * 60)
      setup_otel
      vm.sshable.cmd("sudo systemctl enable --now otelcol-contrib")
      vm.sshable.cmd("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")
      hop_bootstrap_rhizome
    end

    def setup_otel
      tag_attributes = postgres_server.resource.tags.map { |tag|
        safe_key = tag["key"].gsub(/[^a-zA-Z0-9_-]/, "_")
        safe_value = tag["value"].gsub("'", "''")

        <<TAG_ATTR.chomp
      - key: ubi.postgres_resource_tags_label_#{safe_key}
        value: '#{safe_value}'
        action: upsert
TAG_ATTR
      }.join("\n")

      auth_config = if Config.postgres_otel_otlp_export_jwt_oidc_provider_id
        <<AUTH
    auth:
      authenticator: bearertokenauth/otlp-export
AUTH
      else
        ""
      end

      vm.sshable.write_file("/home/otelcol/otel-config-override.yaml", <<OTEL_CONFIG_OVERRIDE, user: "otelcol")
exporters:
  otlp/export:
    endpoint: #{postgres_server.resource.otel_otlp_export_endpoint}
#{auth_config}
processors:
  resource/ubiMetadata:
    attributes:
      - key: ubi.postgres_server_ubid
        value: '#{postgres_server.ubid}'
        action: upsert
      - key: ubi.postgres_resource_ubid
        value: '#{postgres_server.resource.ubid}'
        action: upsert
      - key: ubi.postgres_resource_uuid
        value: '#{postgres_server.resource.id}'
        action: upsert
      - key: ubi.postgres_server_role
        value: '#{(postgres_server.id == postgres_server.resource.representative_server.id) ? "primary" : "standby"}'
        action: upsert
      - key: ubi.postgres_resource_read_replica
        value: '#{postgres_server.read_replica?}'
        action: upsert
      - key: ubi.postgres_resource_ha_type
        value: '#{postgres_server.resource.ha_type}'
        action: upsert
      - key: ubi.postgres_resource_target_standby_count
        value: '#{postgres_server.resource.target_standby_count}'
        action: upsert
      - key: ubi.postgres_resource_target_server_count
        value: '#{postgres_server.resource.target_server_count}'
        action: upsert
#{tag_attributes}
OTEL_CONFIG_OVERRIDE

      write_otel_token if otel_token_needs_refresh?

      vm_sku_prom = <<~PROM
        # HELP node_memory_sku_total_bytes Total memory in bytes as defined by VM SKU
        # TYPE node_memory_sku_total_bytes gauge
        node_memory_sku_total_bytes #{postgres_server.sku_memory_bytes}
      PROM
      vm.sshable.write_file("/var/lib/node_exporter/vm_sku.prom", vm_sku_prom)
    end

    def otel_token_path
      "/home/otelcol/otlp-export.token"
    end

    def write_otel_token
      return unless Config.postgres_otel_otlp_export_jwt_oidc_provider_id

      oidc_provider = OidcProvider[Config.postgres_otel_otlp_export_jwt_oidc_provider_id]
      unless oidc_provider
        raise "Configured postgres_otel_otlp_export_jwt_oidc_provider_id=#{Config.postgres_otel_otlp_export_jwt_oidc_provider_id} does not correspond to an existing OidcProvider"
      end

      token_url = URI.join(oidc_provider.url, oidc_provider.token_endpoint).to_s
      auth_string = Base64.strict_encode64([CGI.escape(oidc_provider.client_id), CGI.escape(oidc_provider.client_secret)].join(":"))

      audience = postgres_server.resource.otel_otlp_export_endpoint
      body_params = {grant_type: "client_credentials"}
      body_params[:audience] = audience if audience

      if Config.postgres_otel_otlp_export_additional_metadata_field
        metadata = {
          postgres_server_id: postgres_server.ubid,
          postgres_resource_id: postgres_server.resource.ubid,
          postgres_resource_uuid: postgres_server.resource.id,
          postgres_server_role: (postgres_server.id == postgres_server.resource.representative_server.id) ? "primary" : "standby"
        }
        body_params[Config.postgres_otel_otlp_export_additional_metadata_field.to_sym] = JSON.generate(metadata)
      end

      response = Excon.post(
        token_url,
        headers: {
          "Content-Type" => "application/x-www-form-urlencoded",
          "Accept" => "application/json",
          "Authorization" => "Basic #{auth_string}"
        },
        body: URI.encode_www_form(body_params),
        expects: [200, 201]
      )

      token_data = JSON.parse(response.body)
      access_token = token_data["access_token"]

      unless access_token
        raise "OAuth token response missing access_token: #{response.body}"
      end

      vm.sshable.write_file(otel_token_path, access_token, user: "otelcol")
      vm.sshable.cmd("sudo systemctl reload otelcol-contrib || sudo systemctl restart otelcol-contrib")
    end

    def otel_token_needs_refresh?
      return false unless Config.postgres_otel_otlp_export_jwt_oidc_provider_id

      result = vm.sshable.cmd("sudo test -f :otel_token_path && echo exists || echo missing", otel_token_path:)
      return true if result.strip == "missing"

      token = vm.sshable.cmd("sudo cat :otel_token_path", otel_token_path:, log: false).strip
      return true if token.empty?

      begin
        payload, _header = JWT.decode(token, nil, false)
        iat = payload["iat"]
        exp = payload["exp"]

        return true unless iat && exp

        current_time = Time.now.to_i
        validity_duration = exp - iat
        two_thirds_point = iat + (validity_duration * 2 / 3)

        current_time >= two_thirds_point
      rescue JWT::DecodeError
        true
      end
    end
  end
end
