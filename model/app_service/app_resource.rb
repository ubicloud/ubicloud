# frozen_string_literal: true

require_relative "../../model"

class AppResource < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :project
  many_to_one :location, read_only: true
  many_to_one :private_subnet, read_only: true
  many_to_one :secret_store, read_only: true
  many_to_one :load_balancer, read_only: true
  many_to_one :postgres_resource, read_only: true
  one_to_many :servers, class: :AppServer, read_only: true
  one_to_many :processes, class: :AppProcess, read_only: true
  one_to_many :deployments, class: :AppDeployment, read_only: true
  many_to_one :current_deployment, class: :AppDeployment

  plugin ResourceMethods, encrypted_columns: :parseable_password
  plugin SemaphoreMethods, :destroy, :deploy, :converge, :provision_database

  # Default instance size for a process (pod/dyno) when none is specified.
  DEFAULT_VM_SIZE = "hobby-1"

  # User-selectable instance sizes for a process, smallest first. The shared
  # burstable sizes are surfaced under the friendlier "hobby" label (scale()
  # translates them back before validating), so the set here mirrors exactly
  # what scale() accepts: the visible x64 sizes.
  def self.vm_size_options
    Option::VmSizes
      .select { it.visible && it.arch == "x64" }
      .sort_by { [(it.family == "burstable") ? 0 : 1, it.vcpus] }
      .map { it.name.sub("burstable", "hobby") }
  end

  # Managed Postgres role the app authenticates as (certificate auth).
  DB_ROLE_NAME = "app"

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
  rescue Parseable::Client::Error => e
    # Parseable infers a stream's schema from ingested data, so querying a
    # brand-new app's stream (no logs shipped yet) returns 400. Treat any query
    # failure as "no logs available" rather than breaking the page.
    Clog.emit("Could not query app logs from Parseable", {app_resource: ubid, error: e.message})
    []
  end

  # Provision an app-owned managed Postgres with a cert-auth role. Certificate
  # issuance and access grants are deferred to the nexus (via provision_database)
  # because the role's client cert can only be signed once the Postgres has
  # provisioned its client CA. The app then connects with the cert -- no
  # credential is ever stored.
  def attach_database
    DB.transaction do
      pg = Prog::Postgres::PostgresResourceNexus.assemble(
        project_id: Config.app_service_project_id,
        location_id:,
        name: ubid,
        target_vm_size: "standard-2",
        target_storage_size_gib: 64,
      ).subject
      PostgresManagedRole.create(postgres_resource_id: pg.id, name: DB_ROLE_NAME, auth_type: "cert")
      update(postgres_resource_id: pg.id)
      incr_provision_database
      pg
    end
  end

  def detach_database
    DB.transaction do
      pg = postgres_resource
      update(postgres_resource_id: nil)
      pg&.incr_destroy
    end
  end

  def database_role
    postgres_resource&.managed_roles_dataset&.first(name: DB_ROLE_NAME)
  end

  # Grant a VM's managed identity permission to download the DB role's cert.
  # Idempotent: both provision_database and AppServerNexus may try to grant the
  # same server, depending on whether it predates the database.
  def grant_database_access(vm_id)
    role = database_role
    return if AccessControlEntry.where(project_id: Config.app_service_project_id, subject_id: vm_id, object_id: role.id).any?
    AccessControlEntry.create(project_id: Config.app_service_project_id, subject_id: vm_id, action_id: ActionType::NAME_MAP.fetch("PostgresRole:assume"), object_id: role.id)
  end

  # The app's dedicated database -- named after the app and owned by its managed
  # role, so the app can create tables for migrations with no configuration. The
  # app connects here by default; PGDATABASE/DATABASE_URL config can override it.
  def database_name
    name
  end

  # Create the dedicated database (owned by the role) if it doesn't already
  # exist. CREATE DATABASE can't run in a transaction or be IF NOT EXISTS, so we
  # check first; the role must already exist since it owns the database.
  def create_database
    server = postgres_resource.representative_server
    return unless server.run_query(DB[:pg_database].where(datname: database_name).select(1)).empty?
    server.run_query(<<~SQL.freeze)
      CREATE DATABASE "#{database_name}" OWNER "#{DB_ROLE_NAME}";
    SQL
  end

  # User-facing database summary, or nil when no database is attached.
  def database_connection
    return unless (pg = postgres_resource)
    {state: pg.display_state, name: pg.name, database: database_name, user: DB_ROLE_NAME, port: 5432}
  end

  # Connection details handed to the deploy script (transiently, never stored).
  # The script downloads the cert via the VM's managed identity and sets PG* env.
  # Nil until the role's client cert has been issued (Postgres fully provisioned),
  # so deploys don't try to download a cert that doesn't exist yet.
  def database_deploy_config
    return unless (pg = postgres_resource)
    return unless database_role.cert
    {
      host: pg.hostname,
      port: 5432,
      dbname: database_name,
      user: DB_ROLE_NAME,
      cert_url: "/project/#{UBID.to_ubid(Config.app_service_project_id)}#{pg.path}/managed-role/by-name/#{DB_ROLE_NAME}/certificate",
      ca: pg.ca_certificates,
    }
  end

  # API path the app server's managed identity reads config/secrets from. The
  # Secret Store lives in the app service project, so the path must reference
  # that project -- the managed identity is scoped to it, and a mismatched
  # project ubid resolves to "not found".
  def secret_store_path
    "/project/#{UBID.to_ubid(Config.app_service_project_id)}/secret-store/#{secret_store.ubid}/secret"
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

  # A config (Secret Store) change only takes effect on (re)deploy, since the app
  # servers read the store at build/run time. Roll a fresh deployment so the new
  # config lands -- but only once the app has shipped at least once; before the
  # first deploy there is nothing to roll and the config is picked up by it.
  # Returns the new deployment, or nil when no redeploy was needed.
  def redeploy_for_config_change
    deploy if latest_deployment
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

  # Create a process (one replica, default size) for each Procfile process type
  # the build reported that we don't already track, then converge. Existing
  # types hit the unique (app_resource_id, process_type) constraint and are
  # skipped -- which also makes concurrent server deploys safe. `process_types`
  # is the newline-separated list extracted from the built image.
  def discover_processes(process_types)
    created = false
    process_types.split("\n").map(&:strip).reject(&:empty?).each do |process_type|
      AppProcess.create(app_resource_id: id, process_type:, replica_count: 1, vm_size: DEFAULT_VM_SIZE)
      created = true
    rescue Sequel::ValidationFailed, Sequel::UniqueConstraintViolation
      # already tracked (the model's uniqueness check, or the DB constraint when
      # a concurrent server deploy created it first)
    end
    incr_converge if created
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
#  postgres_resource_id  | uuid                     |
# Indexes:
#  app_resource_pkey                              | PRIMARY KEY btree (id)
#  app_resource_project_id_location_id_name_index | UNIQUE btree (project_id, location_id, name)
# Foreign key constraints:
#  app_resource_current_deployment_id_fkey | (current_deployment_id) REFERENCES app_deployment(id)
#  app_resource_load_balancer_id_fkey      | (load_balancer_id) REFERENCES load_balancer(id)
#  app_resource_location_id_fkey           | (location_id) REFERENCES location(id)
#  app_resource_postgres_resource_id_fkey  | (postgres_resource_id) REFERENCES postgres_resource(id)
#  app_resource_private_subnet_id_fkey     | (private_subnet_id) REFERENCES private_subnet(id)
#  app_resource_project_id_fkey            | (project_id) REFERENCES project(id)
#  app_resource_secret_store_id_fkey       | (secret_store_id) REFERENCES secret_store(id)
# Referenced By:
#  app_deployment | app_deployment_app_resource_id_fkey | (app_resource_id) REFERENCES app_resource(id)
#  app_process    | app_process_app_resource_id_fkey    | (app_resource_id) REFERENCES app_resource(id)
#  app_server     | app_server_app_resource_id_fkey     | (app_resource_id) REFERENCES app_resource(id)
