# frozen_string_literal: true

require_relative "../../model"

class PostgresResource < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :project
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active
  many_to_one :parent, class: self
  one_to_many :servers, class: :PostgresServer, key: :resource_id, read_only: true
  one_to_one :representative_server, class: :PostgresServer, key: :resource_id, conditions: {is_representative: true}, read_only: true
  one_through_one :timeline, class: :PostgresTimeline, join_table: :postgres_server, left_key: :resource_id, read_only: true
  one_to_many :metric_destinations, class: :PostgresMetricDestination, remover: nil, clearer: nil
  many_to_one :private_subnet, read_only: true
  many_to_one :location
  one_to_many :read_replicas, class: :PostgresResource, key: :parent_id, conditions: {restore_target: nil}, read_only: true
  one_to_one :init_script, class: :PostgresInitScript, key: :id, read_only: true

  plugin :association_dependencies, metric_destinations: :destroy, init_script: :destroy
  dataset_module Pagination

  plugin ResourceMethods, redacted_columns: [:root_cert_1, :root_cert_2, :server_cert, :trusted_ca_certs],
    encrypted_columns: [:superuser_password, :root_cert_key_1, :root_cert_key_2, :server_cert_key]
  plugin ProviderDispatcher, __FILE__
  plugin SemaphoreMethods, :initial_provisioning, :update_firewall_rules, :refresh_dns_record, :update_billing_records,
    :destroy, :promote, :refresh_certificates, :use_different_az, :use_old_walg_command, :check_disk_usage,
    :storage_auto_scale_action_performed_80, :storage_auto_scale_action_performed_85, :storage_auto_scale_action_performed_90,
    :storage_auto_scale_canceled, :storage_auto_scale_not_cancellable
  include ObjectTag::Cleanup

  ServerExclusionFilters = Struct.new(:exclude_host_ids, :exclude_data_centers, :exclude_availability_zones, :availability_zone)

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/postgres/#{name}"
  end

  def vm_size
    representative_server&.vm&.display_size&.gsub("burstable", "hobby") || target_vm_size
  end

  def storage_size_gib
    representative_server&.storage_size_gib || target_storage_size_gib
  end

  def display_state
    return "deleting" if destroying_set? || destroy_set? || strand.nil?

    server_strand_label = representative_server&.strand&.label
    return "unavailable" if server_strand_label == "unavailable"
    return "restoring_backup" if server_strand_label == "initialize_database_from_backup"
    return "replaying_wal" if ["wait_catch_up", "wait_synchronization"].include?(server_strand_label)
    return "finalizing_restore" if server_strand_label == "wait_recovery_completion"
    return "restarting" if server_strand_label == "restart"
    return "running" if ["wait", "refresh_certificates", "refresh_dns_record"].include?(strand.label) && !initial_provisioning_set?

    "creating"
  end

  def hostname_suffix
    project&.get_ff_postgres_hostname_override || [location.dns_suffix, Config.postgres_service_hostname].compact.join(".")
  end

  def dns_zone
    @dns_zone ||= DnsZone[project_id: Config.postgres_service_project_id, name: hostname_suffix]
  end

  AAAA_CUTOFF = Time.utc(2026, 1, 13, 20)
  def can_add_aaaa_record?
    !location.aws? &&
      created_at < AAAA_CUTOFF &&
      dns_zone &&
      representative_server&.vm&.ip6_string &&
      dns_zone
        .records_dataset
        .where(type: "AAAA", name: hostname + ".")
        .empty?
  end

  def hostname
    if dns_zone
      return "#{name}.#{hostname_suffix}" if hostname_version == "v1"

      "#{name}.#{ubid}.#{hostname_suffix}"
    else
      representative_server&.vm&.ip4_string
    end
  end

  def identity
    "#{ubid}.#{hostname_suffix}"
  end

  def connection_string
    return nil unless (hn = hostname)

    URI::Generic.build2(
      scheme: "postgres",
      userinfo: "postgres:#{URI.encode_uri_component(superuser_password)}",
      host: hn,
      port: 5432,
      path: "/postgres",
      query: "channel_binding=require"
    ).to_s
  end

  def replication_connection_string(application_name:)
    return nil unless dns_zone || representative_server

    query_parameters = {
      sslrootcert: "/etc/ssl/certs/ca.crt",
      sslcert: "/etc/ssl/certs/server.crt",
      sslkey: "/etc/ssl/certs/server.key",
      sslmode: dns_zone ? "verify-full" : "require",
      dbname: "postgres",
      application_name:
    }.map { |k, v| "#{k}=#{v}" }.join("&")

    URI::Generic.build2(scheme: "postgres", userinfo: "ubi_replication", host: dns_zone ? identity : representative_server.vm.ip4_string, query: query_parameters).to_s
  end

  def version
    representative_server&.version || target_version
  end

  def provision_new_standby
    timeline_id = read_replica? ? parent.timeline.id : timeline.id
    Prog::Postgres::PostgresServerNexus.assemble(
      resource_id: id,
      timeline_id:,
      timeline_access: "fetch",
      **new_server_exclusion_filters.to_h
    )
  end

  def target_standby_count
    Option::POSTGRES_HA_OPTIONS[ha_type].standby_count
  end

  def target_server_count
    target_standby_count + 1
  end

  def has_enough_fresh_servers?
    if version.to_i < target_version.to_i
      !upgrade_candidate_server.nil?
    else
      servers.count { !it.needs_recycling? } >= target_server_count
    end
  end

  def has_enough_ready_servers?
    if version.to_i < target_version.to_i
      upgrade_candidate_server&.strand&.label == "wait"
    else
      servers.count { !it.needs_recycling? && it.strand.label == "wait" } >= target_server_count
    end
  end

  def needs_convergence?
    needs_upgrade = version.to_i < target_version.to_i && !ongoing_failover?
    servers.any? { it.needs_recycling? } || servers.count != target_server_count || needs_upgrade
  end

  def in_maintenance_window?
    maintenance_window_start_at.nil? || (Time.now.utc.hour - maintenance_window_start_at) % 24 < MAINTENANCE_DURATION_IN_HOURS
  end

  # This may return nil if the customer has destroyed the firewall or
  # detached it from the private subnet.
  def customer_firewall
    private_subnet.firewalls_dataset.first(name: "#{ubid}-firewall")
  end

  def internal_firewall
    Firewall.first(project_id: Config.postgres_service_project_id, name: "#{ubid}-internal-firewall")
  end

  PG_FIREWALL_RULE_PORT_RANGES = [Sequel.pg_range(5432..5432), Sequel.pg_range(6432..6432)].freeze
  def pg_firewall_rules(firewall: customer_firewall)
    return [] unless firewall

    pg_firewall_rules_dataset(firewall:).all
  end

  def pg_firewall_rule(id, firewall: customer_firewall)
    pg_firewall_rules_dataset(firewall:).first(id:)
  end

  def pg_firewall_rules_dataset(firewall: customer_firewall)
    firewall.firewall_rules_dataset
      .where(port_range: PG_FIREWALL_RULE_PORT_RANGES)
      .order(:cidr, :port_range)
  end

  def ca_certificates
    [root_cert_1, root_cert_2].join("\n") if root_cert_1 && root_cert_2
  end

  def validate
    super
    validates_includes(0..23, :maintenance_window_start_at, allow_nil: true, message: "must be between 0 and 23")
  end

  def read_replica?
    parent_id && restore_target.nil?
  end

  def ongoing_failover?
    servers.any? { it.taking_over? }
  end

  def incr_restart
    Semaphore.incr(servers_dataset.select(:id), "restart")
  end

  def upgrade_stage
    strand.children_dataset.where(prog: "Postgres::ConvergePostgresResource").first&.label
  end

  def upgrade_status
    if upgrade_stage == "upgrade_failed"
      "failed"
    elsif target_version != version
      "running"
    else
      "not_running"
    end
  end

  def can_upgrade?
    target_version.to_i < Option::POSTGRES_VERSION_OPTIONS[flavor].map(&:to_i).max
  end

  def ready_for_read_replica?
    !needs_convergence? && !PostgresTimeline.earliest_restore_time(timeline).nil?
  end

  def handle_storage_auto_scale
    return unless representative_server

    begin
      disk_usage_percent = representative_server.vm.sshable.cmd("df --output=pcent /dat | tail -n 1").strip.delete("%").to_i
    rescue
      Clog.emit("Failed to check disk usage for #{ubid}, skipping storage auto-scale check", representative_server)
      return
    end

    # Clear semaphores only when usage drops at least 5% below threshold to avoid spurious emails
    [90, 85, 80].each {
      send("decr_storage_auto_scale_action_performed_#{it}") if disk_usage_percent <= it - 5
    }

    if disk_usage_percent <= 75
      Page.from_tag_parts("PGStorageAutoScaleMaxSize", id)&.incr_resolve
      Page.from_tag_parts("PGStorageAutoScaleQuotaInsufficient", id)&.incr_resolve
      Page.from_tag_parts("PGStorageAutoScaleCanceled", id)&.incr_resolve
      decr_storage_auto_scale_canceled
    end

    return if disk_usage_percent < 80
    return if disk_usage_percent < 85 && storage_auto_scale_action_performed_80_set?
    return if disk_usage_percent < 90 && storage_auto_scale_action_performed_85_set?
    return if storage_auto_scale_action_performed_90_set?

    # target_storage_size_gib being bigger than representative server's storage
    # size means storage auto-scale is in progress, so we should not trigger
    # another auto-scale or send warning emails.
    return if representative_server.storage_size_gib < target_storage_size_gib

    next_option = next_storage_auto_scale_option

    extra_email_content = if storage_auto_scale_canceled_set?
      :canceled_previously
    elsif next_option.nil?
      Prog::PageNexus.assemble("#{ubid} high disk usage #{disk_usage_percent}%. No further auto-scaling possible.", ["PGStorageAutoScaleMaxSize", id], ubid, severity: "warning")
      :at_max_size
    elsif !project.quota_available?("PostgresVCpu", vcpu_delta(next_option))
      Prog::PageNexus.assemble("#{ubid} high disk usage #{disk_usage_percent}%. Quota insufficient for auto-scale.", ["PGStorageAutoScaleQuotaInsufficient", id], ubid, severity: "warning")
      :quota_insufficient
    end

    [90, 85, 80].each {
      send("incr_storage_auto_scale_action_performed_#{it}") if disk_usage_percent >= it && !send("storage_auto_scale_action_performed_#{it}_set?")
    }

    if disk_usage_percent < 90
      send_storage_auto_scale_warning_notification(disk_usage_percent, next_option, extra_email_content)
    else
      if next_option
        target_vm_size = next_option["size"]
        target_storage_size_gib = next_option["storage_size"]

        unless storage_auto_scale_canceled_set?
          update(target_vm_size:, target_storage_size_gib:)
          read_replicas_dataset.update(target_vm_size:, target_storage_size_gib:)
        end
      end

      send_storage_auto_scale_started_notification(disk_usage_percent, next_option, extra_email_content)
    end
  end

  def next_storage_auto_scale_option
    option_tree, parents = PostgresResource.generate_postgres_options(project, flavor:, location:)
    all_storage_size_options = OptionTreeGenerator.generate_allowed_options("storage_size", option_tree, parents)

    current_vm_size = Option::POSTGRES_SIZE_OPTIONS[vm_size]
    vcpu_count = current_vm_size.vcpu_count
    family = current_vm_size.family
    allowed_families = [family]
    allowed_families << "standard" if family == "hobby"

    all_storage_size_options.select { allowed_families.include?(it["family"]) && Option::POSTGRES_SIZE_OPTIONS[it["size"]].vcpu_count >= vcpu_count && it["storage_size"] > representative_server.storage_size_gib }
      .min_by { [Option::POSTGRES_SIZE_OPTIONS[it["size"]].vcpu_count, it["storage_size"]] }
  end

  def vcpu_delta(target_option)
    current_vcpu = Option::POSTGRES_SIZE_OPTIONS[vm_size].vcpu_count
    new_vcpu = Option::POSTGRES_SIZE_OPTIONS[target_option["size"]].vcpu_count
    vcpu_delta = new_vcpu - current_vcpu

    total_server_count = target_server_count + read_replicas.sum(&:target_server_count)
    vcpu_delta * total_server_count
  end

  def storage_auto_scale_lock_key
    Digest::SHA2.digest(id).unpack1("q>").abs
  end

  def can_cancel_storage_auto_scale?
    return false if storage_auto_scale_canceled_set? || storage_auto_scale_not_cancellable_set? || !storage_auto_scale_action_performed_90_set?

    converge_strand = strand.children_dataset.where(prog: "Postgres::ConvergePostgresResource").first
    return false unless converge_strand

    ["start", "provision_servers", "wait_servers_to_be_ready", "wait_for_maintenance_window"].include?(converge_strand.label)
  end

  def cancel_storage_auto_scale
    DB.transaction do
      # Try to acquire advisory lock to prevent race with failover
      unless DB.get(Sequel.function(:pg_try_advisory_xact_lock, storage_auto_scale_lock_key))
        return false
      end

      return false unless can_cancel_storage_auto_scale?

      current_storage_size_gib = representative_server.storage_size_gib
      update(target_vm_size: vm_size, target_storage_size_gib: current_storage_size_gib)
      read_replicas_dataset.update(target_vm_size: vm_size, target_storage_size_gib: current_storage_size_gib)

      incr_storage_auto_scale_canceled

      Prog::PageNexus.assemble("#{ubid} storage auto-scale canceled by user", ["PGStorageAutoScaleCanceled", id], ubid, severity: "warning")

      send_storage_auto_scale_canceled_notification

      true
    end
  end

  def send_storage_auto_scale_warning_notification(usage_percent, next_option, extra_content)
    body = [
      "Your PostgreSQL database '#{name}' (#{ubid}) has reached #{usage_percent}% disk usage.",
      "You are currently using #{storage_size_gib * usage_percent / 100} of #{storage_size_gib} GB of storage."
    ]

    if [:canceled_previously, :at_max_size, :quota_insufficient].include?(extra_content)
      body << "Automated disk scaling is normally triggered when disk usage exceeds 90%."
      body << if extra_content == :canceled_previously
        "However, you previously canceled auto-scaling, so auto-scaling will stay deactivated until disk usage drops below 80%."
      elsif extra_content == :at_max_size
        "However, your database has already reached the maximum available storage size, so auto-scaling cannot proceed."
      else
        "However, your project does not have sufficient quota, so auto-scaling cannot proceed."
      end
      body << "Please free up disk space or contact support for assistance."
    else
      body << "When disk usage reaches 90%, storage will be automatically increased to #{next_option["storage_size"]} GB."
      if next_option["size"] != vm_size
        body << "Since your current instance size does not support the new storage size, the instance will also be upgraded from #{vm_size} to #{next_option["size"]}."
      end
      body << "Disk scaling requires a cutover to a new server, which will result in a short downtime, typically less than a minute. The scaling operation will be triggered automatically once disk usage reaches 90%."
      body << "If you wish to scale sooner or have any questions, please contact support."
      body << "Your database also has read replica(s), which will be scaled alongside the primary instance." if read_replicas.any?
    end

    Util.send_email(
      accounts_with_access.map(&:email).uniq,
      "PostgreSQL Storage Warning: #{name} at #{usage_percent}% capacity",
      bcc: Config.postgres_notification_email,
      greeting: "Hello,",
      body:,
      button_title: "View Database",
      button_link: "#{Config.base_url}#{project.path}#{path}"
    )
  end

  def send_storage_auto_scale_started_notification(usage_percent, next_option, extra_content)
    body = [
      "Your PostgreSQL database '#{name}' (#{ubid}) has reached #{usage_percent}% disk usage.",
      "You are currently using #{storage_size_gib * usage_percent / 100} of #{storage_size_gib} GB of storage."
    ]

    if [:canceled_previously, :at_max_size, :quota_insufficient].include?(extra_content)
      body << "Auto-scaling would normally begin at this threshold."
      body << if extra_content == :canceled_previously
        "However, you previously canceled auto-scaling, so auto-scaling will stay deactivated until disk usage drops below 80%."
      elsif extra_content == :at_max_size
        "However, your database has already reached the maximum available storage size."
      else
        "However, your project does not have sufficient quota."
      end
      body << "Immediate action required. Please free up disk space or contact support."
    else
      body << "Auto-scaling has been initiated. Storage is being increased from #{storage_size_gib} GB to #{next_option["storage_size"]} GB."
      if next_option["size"] != vm_size
        body << "Also, the instance is being upgraded from #{vm_size} to #{next_option["size"]}."
      end

      body << "We are currently preparing a new server with increased storage. The preparation time depends on the size of your database, and you may continue using the database as usual during this process."
      body << "Once the new server is ready, we will automatically cut over to it. If you have a maintenance window configured, the cutover will be scheduled accordingly. The expected downtime is typically less than one minute."
      body << "If this is not a good time for the cutover, you can cancel the auto-scaling before the new server is ready. Please go to the database's settings page to cancel if needed."

      body << "Your database also has read replica(s), which will be scaled alongside the primary instance." if read_replicas.any?
    end

    Util.send_email(
      accounts_with_access.map(&:email).uniq,
      "PostgreSQL Auto-Scaling: #{name}",
      bcc: Config.postgres_notification_email,
      greeting: "Hello,",
      body:,
      button_title: "View Database",
      button_link: "#{Config.base_url}#{project.path}#{path}"
    )
  end

  def send_storage_auto_scale_canceled_notification
    body = [
      "Auto-scaling for your PostgreSQL database '#{name}' (#{ubid}) has been canceled as requested.",
      "Automatic scale-up will not be re-triggered until disk usage drops below 80% and rises again.",
      "The target configuration has been reset to the current values:",
      "Storage: #{representative_server.storage_size_gib} GB",
      "Instance size: #{vm_size}",
      "Please note that if disk usage reaches to 100%, database would become unavailable.",
      "We recommend freeing up disk space or contacting support to discuss other options."
    ]

    Util.send_email(
      accounts_with_access.map(&:email).uniq,
      "PostgreSQL Auto-Scaling Canceled: #{name}",
      bcc: Config.postgres_notification_email,
      greeting: "Hello,",
      body:,
      button_title: "View Database",
      button_link: "#{Config.base_url}#{project.path}#{path}"
    )
  end

  def accounts_with_access
    project.accounts.select { Authorization.has_permission?(project, it, "Postgres:view", project) }
  end

  def self.generate_postgres_options(project, flavor: nil, location: nil)
    options = OptionTreeGenerator.new

    options.add_option(name: "name")

    options.add_option(name: "flavor", values: flavor || postgres_flavors(project).keys)

    options.add_option(name: "location", values: location || postgres_locations(project), parent: "flavor") do |flavor, location|
      flavor == PostgresResource.default_flavor || location.provider != "aws"
    end

    options.add_option(name: "family", values: Option::POSTGRES_FAMILY_OPTIONS.keys, parent: "location") do |flavor, location, family|
      if location.aws?
        ["m8gd", "i8g"].include?(family) || (Option::AWS_FAMILY_OPTIONS.include?(family) && project.send(:"get_ff_enable_#{family}"))
      elsif location.gcp?
        Option::GCP_FAMILY_OPTIONS.include?(family)
      else
        family == "standard" || family == "hobby"
      end
    end

    options.add_option(name: "size", values: Option::POSTGRES_SIZE_OPTIONS.keys, parent: "family") do |flavor, location, family, size|
      Option::POSTGRES_SIZE_OPTIONS[size].family == family
    end

    storage_size_options = Option::POSTGRES_STORAGE_SIZE_OPTIONS +
      Option::AWS_STORAGE_SIZE_OPTIONS.values.flat_map { |h| h.values.flatten }.uniq +
      Option::GCP_STORAGE_SIZE_OPTIONS.values.flat_map { |h| h.values.flatten }.uniq
    options.add_option(name: "storage_size", values: storage_size_options, parent: "size") do |flavor, location, family, size, storage_size|
      vcpu_count = Option::POSTGRES_SIZE_OPTIONS[size].vcpu_count

      if location.aws?
        Option::AWS_STORAGE_SIZE_OPTIONS[family][vcpu_count].include?(storage_size)
      elsif location.gcp?
        Option::GCP_STORAGE_SIZE_OPTIONS[family][vcpu_count].include?(storage_size)
      else
        min_storage = (vcpu_count >= 30) ? 1024 : vcpu_count * 32
        min_storage /= 2 if family == "hobby"
        [min_storage, min_storage * 2, min_storage * 4].include?(storage_size)
      end
    end

    options.add_option(name: "version", values: Option::POSTGRES_VERSION_OPTIONS.values.flatten.uniq, parent: "flavor") do |flavor, version|
      Option::POSTGRES_VERSION_OPTIONS[flavor].include?(version)
    end

    options.add_option(name: "ha_type", values: Option::POSTGRES_HA_OPTIONS.keys, parent: "storage_size")

    if project.get_ff_postgres_init_script
      options.add_option(name: "init_script")
    end

    options.serialize
  end

  def self.postgres_flavors(project)
    Option::POSTGRES_FLAVOR_OPTIONS.reject { |k,| (k == Flavor::LANTERN && !project.get_ff_postgres_lantern) || (k == Flavor::PARADEDB && !project.get_ff_postgres_paradedb) }
  end

  def self.postgres_locations(project)
    Location.postgres_locations + project.locations
  end

  module HaType
    NONE = "none"
    ASYNC = "async"
    SYNC = "sync"
  end

  def self.ha_type_none
    HaType::NONE
  end

  module Flavor
    STANDARD = "standard"
    PARADEDB = "paradedb"
    LANTERN = "lantern"
  end

  def self.default_flavor
    Flavor::STANDARD
  end

  def self.partner_notification_flavors
    [PostgresResource::Flavor::PARADEDB, PostgresResource::Flavor::LANTERN]
  end

  def requires_partner_notification_email?
    self.class.partner_notification_flavors.include?(flavor)
  end

  DEFAULT_VERSION = "17"
  LATEST_VERSION = "18"

  def self.default_version
    DEFAULT_VERSION
  end

  MAINTENANCE_DURATION_IN_HOURS = 2

  def self.maintenance_hour_options
    Array.new(24) do
      [it, "#{"%02d" % it}:00 - #{"%02d" % ((it + MAINTENANCE_DURATION_IN_HOURS) % 24)}:00 (UTC)"]
    end
  end

  UPGRADE_IMAGE_MIN_VERSIONS = {
    "17" => "20240801",
    "18" => "20251021"
  }
end

# Table: postgres_resource
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT now()
#  project_id                  | uuid                     | NOT NULL
#  name                        | text                     | NOT NULL
#  target_vm_size              | text                     | NOT NULL
#  target_storage_size_gib     | bigint                   | NOT NULL
#  superuser_password          | text                     | NOT NULL
#  root_cert_1                 | text                     |
#  root_cert_key_1             | text                     |
#  server_cert                 | text                     |
#  server_cert_key             | text                     |
#  root_cert_2                 | text                     |
#  root_cert_key_2             | text                     |
#  certificate_last_checked_at | timestamp with time zone | NOT NULL DEFAULT now()
#  parent_id                   | uuid                     |
#  restore_target              | timestamp with time zone |
#  ha_type                     | ha_type                  | NOT NULL DEFAULT 'none'::ha_type
#  hostname_version            | hostname_version         | NOT NULL DEFAULT 'v1'::hostname_version
#  private_subnet_id           | uuid                     |
#  flavor                      | postgres_flavor          | NOT NULL DEFAULT 'standard'::postgres_flavor
#  location_id                 | uuid                     | NOT NULL
#  maintenance_window_start_at | integer                  |
#  user_config                 | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  pgbouncer_user_config       | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  tags                        | jsonb                    | NOT NULL DEFAULT '[]'::jsonb
#  target_version              | text                     | NOT NULL
#  trusted_ca_certs            | text                     |
#  cert_auth_users             | jsonb                    | NOT NULL DEFAULT '[]'::jsonb
# Indexes:
#  postgres_server_pkey                               | PRIMARY KEY btree (id)
#  postgres_resource_project_id_location_id_name_uidx | UNIQUE btree (project_id, location_id, name)
# Check constraints:
#  target_version_check               | (target_version = ANY (ARRAY['16'::text, '17'::text, '18'::text]))
#  valid_maintenance_windows_start_at | (maintenance_window_start_at >= 0 AND maintenance_window_start_at <= 23)
# Foreign key constraints:
#  postgres_resource_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_init_script        | postgres_init_script_id_fkey                          | (id) REFERENCES postgres_resource(id)
#  postgres_metric_destination | postgres_metric_destination_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
