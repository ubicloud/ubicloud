# frozen_string_literal: true

require "base64"

require_relative "../../model"

class AppServer < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :app_resource
  many_to_one :app_process
  many_to_one :vm, read_only: true
  many_to_one :current_deployment, class: :AppDeployment

  plugin ResourceMethods
  plugin SemaphoreMethods, :destroy, :deploy

  def web?
    app_process.web?
  end

  # A server is stale when its VM size no longer matches its process's desired
  # size ("hobby" is the customer-facing alias for "burstable").
  def needs_recycling?
    vm.display_size != app_process.vm_size.gsub("hobby", "burstable")
  end

  # Config pushed to the VM's log agent: forwards this server's build + runtime
  # logs to the app's stream on the shared Parseable instance.
  def logs_config
    {
      instance: ubid,
      process_type: app_process.process_type,
      resource_name: app_resource.name,
      resource_id: app_resource.ubid,
      log_destinations: [managed_parseable_destination].compact,
    }
  end

  def managed_parseable_destination
    common_headers = {"X-P-Stream" => app_resource.ubid, "X-P-Log-Source" => "otel-logs"}
    if (override = Config.parseable_endpoint_override)
      {type: "otlp", url: override, options: {"encoding" => "json", "headers" => common_headers}}
    elsif (pr = ParseableResource.for_project(Config.postgres_service_project_id)) && (ps = pr.servers.first)
      headers = {
        "Authorization" => "Basic " + Base64.strict_encode64("#{app_resource.ubid}:#{app_resource.parseable_password}"),
        **common_headers,
      }
      {type: "otlp", url: ps.endpoint, options: {"encoding" => "json", "headers" => headers, "ca_bundle" => pr.root_certs}}
    end
  end
end

# Table: app_server
# Columns:
#  id                    | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(342)
#  app_resource_id       | uuid                     | NOT NULL
#  vm_id                 | uuid                     |
#  created_at            | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  current_deployment_id | uuid                     |
#  app_process_id        | uuid                     |
# Indexes:
#  app_server_pkey                  | PRIMARY KEY btree (id)
#  app_server_app_resource_id_index | btree (app_resource_id)
# Foreign key constraints:
#  app_server_app_process_id_fkey        | (app_process_id) REFERENCES app_process(id)
#  app_server_app_resource_id_fkey       | (app_resource_id) REFERENCES app_resource(id)
#  app_server_current_deployment_id_fkey | (current_deployment_id) REFERENCES app_deployment(id)
#  app_server_vm_id_fkey                 | (vm_id) REFERENCES vm(id)
