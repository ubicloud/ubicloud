# frozen_string_literal: true

require "uri"
require_relative "../../model"
require_relative "../../lib/net_ssh"

class PostgresServer < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :resource, class: :PostgresResource
  many_to_one :timeline, class: :PostgresTimeline
  many_to_one :vm, read_only: true

  plugin ResourceMethods
  plugin ProviderDispatcher, __FILE__
  plugin SemaphoreMethods, :initial_provisioning, :refresh_certificates, :update_superuser_password, :checkup,
    :restart, :configure, :fence, :unfence, :planned_take_over, :unplanned_take_over, :configure_metrics,
    :destroy, :recycle, :promote, :refresh_walg_credentials, :configure_s3_new_timeline, :lockout, :use_physical_slot
  include HealthMonitorMethods
  include MetricsTargetMethods

  def self.victoria_metrics_client
    VictoriaMetricsResource.client_for_project(Config.postgres_service_project_id)
  end

  def before_destroy
    super
    lsn_monitor_ds.delete
  end

  def aws?
    (vm || timeline).location.aws?
  end

  def provider_name
    (vm || timeline).location.provider_name
  end

  def configure_hash
    configs = {
      "listen_addresses" => "'*'",
      "max_connections" => "500",
      "superuser_reserved_connections" => "3",
      "shared_buffers" => "#{vm.memory_gib * 1024 / 4}MB",
      "work_mem" => "#{[vm.memory_gib / 8, 1].max}MB",
      "maintenance_work_mem" => "#{vm.memory_gib * 1024 / 16}MB",
      "max_parallel_workers" => "4",
      "max_parallel_workers_per_gather" => "2",
      "max_parallel_maintenance_workers" => "2",
      "min_wal_size" => "80MB",
      "max_wal_size" => "5GB",
      "random_page_cost" => "1.1",
      "effective_cache_size" => "#{vm.memory_gib * 1024 * 3 / 4}MB",
      "effective_io_concurrency" => "200",
      "tcp_keepalives_count" => "4",
      "tcp_keepalives_idle" => "2",
      "tcp_keepalives_interval" => "2",
      "ssl" => "on",
      "ssl_min_protocol_version" => "TLSv1.3",
      "ssl_ca_file" => "'/etc/ssl/certs/ca.crt'",
      "ssl_cert_file" => "'/etc/ssl/certs/server.crt'",
      "ssl_key_file" => "'/etc/ssl/certs/server.key'",
      "log_timezone" => "'UTC'",
      "log_directory" => "'pg_log'",
      "log_filename" => "'postgresql.log'",
      "log_truncate_on_rotation" => "true",
      "logging_collector" => "on",
      "timezone" => "'UTC'",
      "lc_messages" => "'C.UTF-8'",
      "lc_monetary" => "'C.UTF-8'",
      "lc_numeric" => "'C.UTF-8'",
      "lc_time" => "'C.UTF-8'",
      "shared_preload_libraries" => "'pg_cron,pg_stat_statements'",
      "cron.use_background_workers" => "on"
    }

    if resource.flavor == PostgresResource::Flavor::PARADEDB
      configs["shared_preload_libraries"] = "'pg_cron,pg_stat_statements,pg_analytics,pg_search'"
    elsif resource.flavor == PostgresResource::Flavor::LANTERN
      configs["shared_preload_libraries"] = "'pg_cron,pg_stat_statements,lantern_extras'"
      configs["lantern.external_index_host"] = "'external-indexing.cloud.lantern.dev'"
      configs["lantern.external_index_port"] = "443"
      configs["lantern.external_index_secure"] = "true"
      configs["hnsw.external_index_host"] = "'external-indexing.cloud.lantern.dev'"
      configs["hnsw.external_index_port"] = "443"
      configs["hnsw.external_index_secure"] = "true"
    end

    if version.to_i >= 17
      configs["allow_alter_system"] = "off"
    end

    caught_up_standbys = nil
    if timeline.blob_storage
      configs[:archive_mode] = "on"
      configs[:archive_timeout] = "60"
      configs[:archive_command] = if resource.use_old_walg_command_set?
        "'/usr/bin/wal-g wal-push %p --config /etc/postgresql/wal-g.env'"
      else
        "'/usr/bin/walg-daemon-client /tmp/wal-g wal-push %f'"
      end

      if primary?
        caught_up_standbys = resource.servers.select { it.standby? && it.synchronization_status == "ready" }
        if resource.ha_type == PostgresResource::HaType::SYNC
          configs[:synchronous_standby_names] = "'ANY 1 (#{caught_up_standbys.map(&:ubid).join(",")})'" unless caught_up_standbys.empty?
        end
        if version.to_i >= 17
          configs[:synchronized_standby_slots] = "'#{caught_up_standbys.map(&:ubid).join(",")}'"
        end
      end

      if standby?
        configs[:primary_conninfo] = "'#{resource.replication_connection_string(application_name: ubid)}'"
        configs[:primary_slot_name] = "'#{ubid}'" if physical_slot_ready
      end

      if doing_pitr?
        configs[:recovery_target_time] = "'#{resource.restore_target}'"
      end

      if standby? || doing_pitr?
        configs[:restore_command] = "'/usr/bin/wal-g wal-fetch %f %p --config /etc/postgresql/wal-g.env'"
      end

      add_provider_configs(configs)
    end

    {
      configs:,
      user_config: resource.user_config,
      pgbouncer_user_config: resource.pgbouncer_user_config,
      physical_slots: caught_up_standbys&.map(&:ubid),
      private_subnets: vm.private_subnets.map {
        {
          net4: it.net4.to_s,
          net6: it.net6.to_s
        }
      },
      cert_auth_users: resource.cert_auth_users,
      identity: resource.identity,
      hosts: "#{resource.representative_server.vm.private_ipv4} #{resource.identity}",
      pgbouncer_instances: (vm.vcpus / 2.0).ceil.clamp(1, 8),
      metrics_config:
    }
  end

  def trigger_failover(mode:)
    unless is_representative
      Clog.emit("Cannot trigger failover on a non-representative server", {ubid:})
      return false
    end

    unless (standby = failover_target)
      Clog.emit("No suitable standby found for failover", {ubid:})
      return false
    end

    standby.send(:"incr_#{mode}_take_over")
    true
  end

  def primary?
    timeline_access == "push"
  end

  def standby?
    timeline_access == "fetch" && !doing_pitr?
  end

  def doing_pitr?
    !resource.representative_server.primary?
  end

  def read_replica?
    resource.read_replica?
  end

  def paradedb_and_primary?
    primary? && resource.flavor == PostgresResource::Flavor::PARADEDB
  end

  def storage_size_gib
    vm.vm_storage_volumes.reject(&:boot).sum(&:size_gib)
  end

  def needs_recycling?
    recycle_set? || vm.display_size.gsub("burstable", "hobby") != resource.target_vm_size || storage_size_gib != resource.target_storage_size_gib || version != resource.target_version
  end

  def lsn_caught_up
    parent_server = if read_replica?
      resource.parent&.representative_server
    else
      resource.representative_server
    end

    !parent_server || lsn_diff(parent_server.current_lsn, current_lsn) < 80 * 1024 * 1024
  end

  def current_lsn
    run_query(DB.select(Sequel.function(lsn_function_name)))
  end

  def lsn_monitor_ds
    POSTGRES_MONITOR_DB[:postgres_lsn_monitor].where(postgres_server_id: id)
  end

  def failover_target
    target = resource.servers
      .reject { it.is_representative }
      .select { it.strand.label == "wait" && !it.needs_recycling? }
      .map { {server: it, lsn: it.current_lsn} }
      .max_by { [it[:server].physical_slot_ready ? 1 : 0, lsn2int(it[:lsn])] } # prefers physical slot ready servers

    return nil if target.nil?

    if resource.ha_type == PostgresResource::HaType::ASYNC
      return unless (last_known_lsn = lsn_monitor_ds.get(:last_known_lsn))
      return if lsn_diff(last_known_lsn, target[:lsn]) > 80 * 1024 * 1024 # 80 MB or ~5 WAL files
    end

    target[:server]
  end

  def lsn_function_name
    if primary?
      "pg_current_wal_lsn"
    elsif standby?
      "pg_last_wal_receive_lsn"
    else
      "pg_last_wal_replay_lsn"
    end
  end

  def init_health_monitor_session
    FileUtils.rm_rf(health_monitor_socket_path)
    FileUtils.mkdir_p(health_monitor_socket_path)

    ssh_session = vm.sshable.start_fresh_session
    ssh_session.forward.local_socket(File.join(health_monitor_socket_path, ".s.PGSQL.5432"), "/var/run/postgresql/.s.PGSQL.5432")
    {
      ssh_session:,
      db_connection: nil
    }
  end

  def init_metrics_export_session
    ssh_session = vm.sshable.start_fresh_session
    {
      ssh_session:
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      session[:db_connection] ||= Sequel.connect(adapter: "postgres", host: health_monitor_socket_path, user: "postgres", connect_timeout: 4, keep_reference: false)
      last_known_lsn = session[:db_connection].get(Sequel.function(lsn_function_name).as(:lsn))
      "up"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse:, reading:, data: {last_known_lsn:})

    DB.transaction do
      if pulse[:reading] == "up" && pulse[:reading_rpt] % 12 == 1
        begin
          update_last_known_lsn(last_known_lsn)
        rescue Sequel::Error => ex
          Clog.emit("Failed to update last known lsn", {lsn_update_error: Util.exception_to_hash(ex, into: {ubid:, last_known_lsn:})})
        end
      end

      if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30 && !reload.checkup_set?
        incr_checkup
      end
    end

    pulse
  end

  def update_last_known_lsn(last_known_lsn)
    POSTGRES_MONITOR_DB[:postgres_lsn_monitor]
      .insert_conflict(target: :postgres_server_id, update: {last_known_lsn:})
      .insert(postgres_server_id: id, last_known_lsn:)
  end

  def needs_event_loop_for_pulse_check?
    true
  end

  def health_monitor_socket_path
    @health_monitor_socket_path ||= File.join(Dir.pwd, "var", "health_monitor_sockets", "pg_#{vm.ip6}")
  end

  def lsn2int(lsn)
    lsn.split("/").map { it.rjust(8, "0") }.join.hex
  end

  def lsn_diff(lsn1, lsn2)
    lsn2int(lsn1) - lsn2int(lsn2)
  end

  def run_query(query)
    if query.is_a?(Sequel::Dataset)
      query = query.no_auto_parameterize.sql
    elsif !query.frozen?
      raise NetSsh::PotentialInsecurity, "Interpolated string passed to PostgresServer#run_query at #{caller(1, 1).first}\nReplace string interpolation with a Sequel dataset."
    end

    _run_query(query)
  end

  private def _run_query(query)
    vm.sshable.cmd("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: query).chomp
  end

  def export_metrics(session:, tsdb_client:)
    session[:export_count] ||= 0
    session[:export_count] += 1

    # Check archival, metrics backlog and disk usage every 12 exports. We do
    # this in metrics export rather than pulse check because the metrics export
    # session does not use an event loop. Calling exec! on an SSH session with
    # an active event loop is not thread-safe and leads to stuck sessions.
    if session[:export_count] % 12 == 1
      observe_archival_backlog(session)
      observe_metrics_backlog(session)
      observe_disk_usage(session)
    end

    # Call parent implementation to export actual metrics
    super
  end

  def metrics_config
    ignored_timeseries_patterns = [
      "pg_stat_user_tables_.*",
      "pg_statio_user_tables_.*"
    ]
    exclude_pattern = ignored_timeseries_patterns.join("|")
    query_params = {
      "match[]": "{__name__!~'#{exclude_pattern}'}"
    }
    query_str = URI.encode_www_form(query_params)
    additional_labels = resource.tags.to_h { |tag| ["pg_tags_label_#{tag["key"]}", tag["value"]] }
    additional_labels.merge!({
      location_id: UBID.from_uuidish(resource.location_id),
      location_name: resource.location.name,
      location_provider: resource.location.provider,
      location_display_name: resource.location.display_name
    })

    {
      endpoints: [
        "https://localhost:9090/federate?#{query_str}"
      ],
      max_file_retention: 120,
      interval: "15s",
      additional_labels:,
      metrics_dir: "/home/ubi/postgres/metrics",
      project_id: Config.postgres_service_project_id
    }
  end

  def taking_over?
    unplanned_take_over_set? || planned_take_over_set? || FAILOVER_LABELS.include?(strand.label)
  end

  def switch_to_new_timeline(parent_id: timeline.id)
    # We have to stop wal-g before updating the timeline to avoid WAL files
    # being pushed to the old bucket.
    vm.sshable.cmd("sudo systemctl stop wal-g") if timeline.blob_storage && !resource.use_old_walg_command_set?
    update(
      timeline_id: Prog::Postgres::PostgresTimelineNexus.assemble(location_id: resource.location_id, parent_id:).id,
      timeline_access: "push"
    )

    increment_s3_new_timeline
    refresh_walg_credentials
  end

  def refresh_walg_credentials
    return if timeline.blob_storage.nil?

    walg_config = timeline.generate_walg_config(version)
    vm.sshable.cmd("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: walg_config)
    refresh_walg_blob_storage_credentials
    vm.sshable.cmd("sudo systemctl restart wal-g") unless resource.use_old_walg_command_set?
  end

  def observe_archival_backlog(session)
    result = session[:ssh_session].exec!(
      "sudo find /dat/:version/data/pg_wal/archive_status -name '*.ready' | wc -l",
      version:
    )
    archival_backlog = Integer(result.strip, 10)

    if archival_backlog > archival_backlog_threshold
      Prog::PageNexus.assemble("#{ubid} archival backlog high",
        ["PGArchivalBacklogHigh", id], ubid,
        severity: "warning", extra_data: {archival_backlog:})
    else
      Page.from_tag_parts("PGArchivalBacklogHigh", id)&.incr_resolve
    end
  rescue => ex
    Clog.emit("Failed to observe archival backlog", Util.exception_to_hash(ex, into: {postgres_server_id: id}))
  end

  def archival_backlog_threshold
    # To make the threshold adaptive to storage size, we set it as percent of
    # the storage size as WAL file count based on the allocated storage size,
    # capped to 1000 to avoid high thresholds on large storage sizes.
    archival_backlog_threshold_percent = 5
    archival_backlog_threshold_count = 1000
    [(storage_size_gib * 1024 / (16 * 100)) * archival_backlog_threshold_percent, archival_backlog_threshold_count].min
  end

  def observe_metrics_backlog(session)
    metrics_done_dir = "#{metrics_config[:metrics_dir]}/done"
    result = session[:ssh_session].exec!(
      "find :metrics_done_dir -name '*.txt' | wc -l",
      metrics_done_dir:
    )
    metrics_backlog = Integer(result.strip, 10)
    metrics_interval = metrics_config[:interval].to_i

    if metrics_backlog * metrics_interval > METRICS_BACKLOG_THRESHOLD_SECONDS
      Prog::PageNexus.assemble("#{ubid} metrics backlog high",
        ["PGMetricsBacklogHigh", id], ubid,
        severity: "warning", extra_data: {metrics_backlog:})
    else
      Page.from_tag_parts("PGMetricsBacklogHigh", id)&.incr_resolve
    end
  rescue => ex
    Clog.emit("Failed to observe metrics backlog", Util.exception_to_hash(ex, into: {postgres_server_id: id}))
  end

  def observe_disk_usage(session)
    disk_usage_percent = session[:ssh_session].exec!("df --output=pcent /dat | tail -n 1").strip.delete("%").to_i
    if reload.primary?
      if (disk_usage_percent >= 77 || resource.storage_auto_scale_action_performed_80_set? || resource.storage_auto_scale_canceled_set?) && !resource.check_disk_usage_set?
        resource.incr_check_disk_usage
      end
    elsif disk_usage_percent >= 95
      Prog::PageNexus.assemble("High disk usage on non-primary PG server (#{disk_usage_percent}%)", ["PGDiskUsageHigh", id], ubid, severity: "warning", extra_data: {disk_usage_percent:})
    else
      Page.from_tag_parts("PGDiskUsageHigh", id)&.incr_resolve
    end
  rescue => ex
    Clog.emit("Failed to observe disk usage", Util.exception_to_hash(ex, into: {postgres_server_id: id}))
  end

  METRICS_BACKLOG_THRESHOLD_SECONDS = 300
  FAILOVER_LABELS = ["prepare_for_unplanned_take_over", "prepare_for_planned_take_over", "wait_fencing_of_old_primary", "taking_over", "lockout", "wait_lockout_attempt", "wait_representative_lockout"].freeze
end

# Table: postgres_server
# Columns:
#  id                     | uuid                     | PRIMARY KEY
#  created_at             | timestamp with time zone | NOT NULL DEFAULT now()
#  resource_id            | uuid                     | NOT NULL
#  vm_id                  | uuid                     |
#  timeline_id            | uuid                     | NOT NULL
#  timeline_access        | timeline_access          | NOT NULL DEFAULT 'push'::timeline_access
#  synchronization_status | synchronization_status   | NOT NULL DEFAULT 'ready'::synchronization_status
#  version                | text                     | NOT NULL
#  physical_slot_ready    | boolean                  | NOT NULL DEFAULT false
#  is_representative      | boolean                  | NOT NULL DEFAULT false
# Indexes:
#  postgres_server_pkey1                             | PRIMARY KEY btree (id)
#  postgres_server_resource_id_is_representative_idx | UNIQUE btree (resource_id) WHERE is_representative IS TRUE
#  postgres_server_resource_id_index                 | btree (resource_id)
# Check constraints:
#  version_check | (version = ANY (ARRAY['16'::text, '17'::text, '18'::text]))
# Foreign key constraints:
#  postgres_server_timeline_id_fkey | (timeline_id) REFERENCES postgres_timeline(id)
#  postgres_server_vm_id_fkey       | (vm_id) REFERENCES vm(id)
