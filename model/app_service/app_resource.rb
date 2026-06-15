# frozen_string_literal: true

require_relative "../../model"

class AppResource < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :project
  many_to_one :location, read_only: true
  many_to_one :private_subnet, read_only: true
  many_to_one :secret_store, read_only: true
  many_to_one :load_balancer, read_only: true
  one_to_many :servers, class: :AppServer, read_only: true
  one_to_many :processes, class: :AppProcess, read_only: true
  one_to_many :deployments, class: :AppDeployment, read_only: true
  many_to_one :current_deployment, class: :AppDeployment

  plugin ResourceMethods, encrypted_columns: :parseable_password
  plugin SemaphoreMethods, :destroy, :deploy, :converge

  # Default instance size for a process (pod/dyno) when none is specified.
  DEFAULT_VM_SIZE = "hobby-1"

  # Provision the app's stream + ingest user on the shared Parseable instance
  # (reused from the Postgres service project), storing the ingest password.
  def setup_log_aggregation
    return unless (client = ParseableResource.client_for_project(Config.postgres_service_project_id))

    client.create_stream(stream_name: ubid)
    client.set_retention(stream_name: ubid, duration_days: ParseableResource::LOG_RETENTION_DAYS)
    client.create_role(role_name: ubid, privileges: [{privilege: "ingestor", resource: {stream: ubid}}])
    password = client.create_user(user_id: ubid, roles: [ubid])
    update(parseable_password: password)
  end

  # Fetch recent build/runtime logs for the app from Parseable. `source` filters
  # to "build" or "runtime" when given.
  def logs(source: nil, limit: 100)
    return [] unless (client = ParseableResource.client_for_project(Config.postgres_service_project_id))

    now = Time.now.utc
    ds = DB.from(Sequel.identifier(ubid))
      .no_auto_parameterize
      .select(:time_unix_nano, :source, :severity_text, :body)
      .exclude(body: nil)
      .reverse(:time_unix_nano)
      .limit(limit)
    ds = ds.where(source:) if source

    client.query(ds.sql, start_time: (now - 1800).iso8601, end_time: now.iso8601).map do |row|
      {timestamp: row["time_unix_nano"], source: row["source"], severity: row["severity_text"], message: row["body"]}
    end
  end

  # Create a new pending deployment (the next numbered release) and signal the
  # resource nexus to roll it out across the app's servers.
  def deploy
    DB.transaction do
      deployment = AppDeployment.create(app_resource_id: id, version: next_deployment_version, status: "pending")
      incr_deploy
      deployment
    end
  end

  def latest_deployment
    deployments_dataset.order(:version).last
  end

  def next_deployment_version
    (deployments_dataset.max(:version) || 0) + 1
  end

  # Set the desired formation for a process type (creating it if needed) and
  # signal the resource nexus to converge the running servers to it.
  def scale(process_type, replica_count:, vm_size: nil)
    DB.transaction do
      process = processes_dataset.first(process_type:)
      new_size = vm_size || process&.vm_size || DEFAULT_VM_SIZE
      # Validate against the real (translated) VM sizes; raises ValidationFailed.
      Validation.validate_vm_size(new_size.gsub("hobby", "burstable"), "x64", only_visible: true)

      if process
        process.update(replica_count:, vm_size: new_size)
      else
        process = AppProcess.create(app_resource_id: id, process_type:, replica_count:, vm_size: new_size)
      end
      incr_converge
      process
    end
  end

  def path
    "/app/#{ubid}"
  end

  def hostname
    load_balancer&.hostname
  end

  def display_state
    return "deleting" if destroy_set?
    (strand&.label == "wait") ? "running" : "creating"
  end
end

# Table: app_resource
# Columns:
#  id                    | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(344)
#  project_id            | uuid                     | NOT NULL
#  location_id           | uuid                     | NOT NULL
#  name                  | text                     | NOT NULL
#  repo_url              | text                     | NOT NULL
#  branch                | text                     | NOT NULL
#  private_subnet_id     | uuid                     |
#  secret_store_id       | uuid                     |
#  created_at            | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  current_deployment_id | uuid                     |
#  load_balancer_id      | uuid                     |
#  parseable_password    | text                     |
# Indexes:
#  app_resource_pkey                              | PRIMARY KEY btree (id)
#  app_resource_project_id_location_id_name_index | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  app_resource_current_deployment_id_fkey | (current_deployment_id) REFERENCES app_deployment(id)
#  app_resource_load_balancer_id_fkey      | (load_balancer_id) REFERENCES load_balancer(id)
#  app_resource_location_id_fkey           | (location_id) REFERENCES location(id)
#  app_resource_private_subnet_id_fkey     | (private_subnet_id) REFERENCES private_subnet(id)
#  app_resource_project_id_fkey            | (project_id) REFERENCES project(id)
#  app_resource_secret_store_id_fkey       | (secret_store_id) REFERENCES secret_store(id)
# Referenced By:
#  app_deployment | app_deployment_app_resource_id_fkey | (app_resource_id) REFERENCES app_resource(id)
#  app_process    | app_process_app_resource_id_fkey    | (app_resource_id) REFERENCES app_resource(id)
#  app_server     | app_server_app_resource_id_fkey     | (app_resource_id) REFERENCES app_resource(id)
