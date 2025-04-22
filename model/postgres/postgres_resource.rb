# frozen_string_literal: true

require_relative "../../model"

class PostgresResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id do |ds| ds.active end
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :servers, class: :PostgresServer, key: :resource_id
  one_to_one :representative_server, class: :PostgresServer, key: :resource_id, conditions: Sequel.~(representative_at: nil)
  one_through_one :timeline, class: :PostgresTimeline, join_table: :postgres_server, left_key: :resource_id, right_key: :timeline_id
  one_to_many :firewall_rules, class: :PostgresFirewallRule, key: :postgres_resource_id
  one_to_many :metric_destinations, class: :PostgresMetricDestination, key: :postgres_resource_id
  many_to_one :private_subnet
  many_to_one :location, key: :location_id, class: :Location
  one_to_many :read_replicas, class: :PostgresResource, key: :parent_id, conditions: {restore_target: nil}

  plugin :association_dependencies, firewall_rules: :destroy, metric_destinations: :destroy
  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include ObjectTag::Cleanup

  semaphore :initial_provisioning, :update_firewall_rules, :refresh_dns_record, :update_billing_records, :destroy

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :root_cert_key_1
    enc.column :root_cert_key_2
    enc.column :server_cert_key
  end

  def display_location
    location.display_name
  end

  def path
    "/location/#{display_location}/postgres/#{name}"
  end

  def display_state
    return "unavailable" if representative_server&.strand&.label == "unavailable"
    return "converging" if strand.children.any? { _1.prog == "Postgres::ConvergePostgresResource" }
    return "running" if ["wait", "refresh_certificates", "refresh_dns_record"].include?(strand.label) && !initial_provisioning_set?
    return "deleting" if destroy_set? || strand.label == "destroy"
    "creating"
  end

  def hostname
    if Prog::Postgres::PostgresResourceNexus.dns_zone
      return "#{name}.#{Config.postgres_service_hostname}" if hostname_version == "v1"
      "#{name}.#{ubid}.#{Config.postgres_service_hostname}"
    else
      representative_server&.vm&.ephemeral_net4&.to_s
    end
  end

  def identity
    "#{ubid}.#{Config.postgres_service_hostname}"
  end

  def connection_string
    return nil unless (hn = hostname)
    URI::Generic.build2(
      scheme: "postgres",
      userinfo: "postgres:#{URI.encode_uri_component(superuser_password)}",
      host: hn,
      query: "channel_binding=require"
    ).to_s
  end

  def replication_connection_string(application_name:)
    query_parameters = {
      sslrootcert: "/etc/ssl/certs/ca.crt",
      sslcert: "/etc/ssl/certs/server.crt",
      sslkey: "/etc/ssl/certs/server.key",
      sslmode: "verify-full",
      application_name: application_name
    }.map { |k, v| "#{k}=#{v}" }.join("\\&")

    URI::Generic.build2(scheme: "postgres", userinfo: "ubi_replication", host: identity, query: query_parameters).to_s
  end

  def target_standby_count
    TARGET_STANDBY_COUNT_MAP[ha_type]
  end

  def target_server_count
    target_standby_count + 1
  end

  def has_enough_fresh_servers?
    servers.count { !_1.needs_recycling? } >= target_server_count
  end

  def has_enough_ready_servers?
    servers.count { !_1.needs_recycling? && _1.strand.label == "wait" } >= target_server_count
  end

  def needs_convergence?
    servers.any? { _1.needs_recycling? } || servers.count != target_server_count
  end

  def set_firewall_rules
    vm_firewall_rules = firewall_rules.map { {cidr: _1.cidr.to_s, port_range: Sequel.pg_range(5432..5432)} }
    vm_firewall_rules.concat(firewall_rules.map { {cidr: _1.cidr.to_s, port_range: Sequel.pg_range(6432..6432)} })
    vm_firewall_rules.push({cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22..22)})
    vm_firewall_rules.push({cidr: "::/0", port_range: Sequel.pg_range(22..22)})
    vm_firewall_rules.push({cidr: private_subnet.net4.to_s, port_range: Sequel.pg_range(5432..5432)})
    vm_firewall_rules.push({cidr: private_subnet.net4.to_s, port_range: Sequel.pg_range(6432..6432)})
    vm_firewall_rules.push({cidr: private_subnet.net6.to_s, port_range: Sequel.pg_range(5432..5432)})
    vm_firewall_rules.push({cidr: private_subnet.net6.to_s, port_range: Sequel.pg_range(6432..6432)})
    private_subnet.firewalls.first.replace_firewall_rules(vm_firewall_rules)
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

  module HaType
    NONE = "none"
    ASYNC = "async"
    SYNC = "sync"
  end

  module Flavor
    STANDARD = "standard"
    PARADEDB = "paradedb"
    LANTERN = "lantern"
  end

  TARGET_STANDBY_COUNT_MAP = {HaType::NONE => 0, HaType::ASYNC => 1, HaType::SYNC => 2}.freeze

  DEFAULT_VERSION = "17"

  MAINTENANCE_DURATION_IN_HOURS = 2

  def self.redacted_columns
    super + [:root_cert_1, :root_cert_2, :server_cert]
  end
end

# Table: postgres_resource
# Columns:
#  id                          | uuid                     | PRIMARY KEY
#  created_at                  | timestamp with time zone | NOT NULL DEFAULT now()
#  updated_at                  | timestamp with time zone | NOT NULL DEFAULT now()
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
#  version                     | postgres_version         | NOT NULL DEFAULT '16'::postgres_version
#  location_id                 | uuid                     | NOT NULL
#  maintenance_window_start_at | integer                  |
# Indexes:
#  postgres_server_pkey                               | PRIMARY KEY btree (id)
#  postgres_resource_project_id_location_id_name_uidx | UNIQUE btree (project_id, location_id, name)
# Check constraints:
#  valid_maintenance_windows_start_at | (maintenance_window_start_at >= 0 AND maintenance_window_start_at <= 23)
# Foreign key constraints:
#  postgres_resource_location_id_fkey | (location_id) REFERENCES location(id)
# Referenced By:
#  postgres_firewall_rule      | postgres_firewall_rule_postgres_resource_id_fkey      | (postgres_resource_id) REFERENCES postgres_resource(id)
#  postgres_metric_destination | postgres_metric_destination_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
