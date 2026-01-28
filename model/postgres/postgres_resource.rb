# frozen_string_literal: true

require_relative "../../model"

class PostgresResource < Sequel::Model
  one_to_one :strand, key: :id, read_only: true
  many_to_one :project
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id, read_only: true, &:active
  many_to_one :parent, class: self
  one_to_many :servers, class: :PostgresServer, key: :resource_id, read_only: true
  one_to_one :representative_server, class: :PostgresServer, key: :resource_id, conditions: Sequel.~(representative_at: nil), read_only: true
  one_through_one :timeline, class: :PostgresTimeline, join_table: :postgres_server, left_key: :resource_id, read_only: true
  one_to_many :metric_destinations, class: :PostgresMetricDestination, remover: nil, clearer: nil
  many_to_one :private_subnet, read_only: true
  many_to_one :location
  one_to_many :read_replicas, class: :PostgresResource, key: :parent_id, conditions: {restore_target: nil}, read_only: true

  plugin :association_dependencies, metric_destinations: :destroy
  dataset_module Pagination

  plugin ResourceMethods, redacted_columns: [:root_cert_1, :root_cert_2, :server_cert, :trusted_ca_certs],
    encrypted_columns: [:superuser_password, :root_cert_key_1, :root_cert_key_2, :server_cert_key]
  plugin ProviderDispatcher, __FILE__
  plugin SemaphoreMethods, :initial_provisioning, :update_firewall_rules, :refresh_dns_record, :update_billing_records, :destroy, :promote, :refresh_certificates, :use_different_az, :use_old_walg_command
  include ObjectTag::Cleanup

  ServerExclusionFilters = Struct.new(:exclude_host_ids, :exclude_data_centers, :exclude_availability_zones, :availability_zone)

  def self.available_flavors(include_lantern: false)
    Option::POSTGRES_FLAVOR_OPTIONS.reject { |k,| k == Flavor::LANTERN && !include_lantern }
  end

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/postgres/#{name}"
  end

  def vm_size
    representative_server&.vm&.display_size || target_vm_size
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
    return nil unless Util.use_dns_zone?(dns_zone) || representative_server

    query_parameters = {
      sslrootcert: "/etc/ssl/certs/ca.crt",
      sslcert: "/etc/ssl/certs/server.crt",
      sslkey: "/etc/ssl/certs/server.key",
      sslmode: Util.use_dns_zone?(dns_zone) ? "verify-full" : "require",
      dbname: "postgres",
      application_name:
    }.map { |k, v| "#{k}=#{v}" }.join("&")

    URI::Generic.build2(scheme: "postgres", userinfo: "ubi_replication", host: Util.use_dns_zone?(dns_zone) ? identity : representative_server.vm.ip4_string, query: query_parameters).to_s
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
#  postgres_metric_destination | postgres_metric_destination_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
