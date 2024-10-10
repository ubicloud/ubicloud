# frozen_string_literal: true

require_relative "../../model"

class PostgresResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id do |ds| ds.active end
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :servers, class: PostgresServer, key: :resource_id
  one_to_one :representative_server, class: PostgresServer, key: :resource_id, conditions: Sequel.~(representative_at: nil)
  one_through_one :timeline, class: PostgresTimeline, join_table: :postgres_server, left_key: :resource_id, right_key: :timeline_id
  one_to_many :firewall_rules, class: PostgresFirewallRule, key: :postgres_resource_id
  one_to_many :metric_destinations, class: PostgresMetricDestination, key: :postgres_resource_id
  many_to_one :private_subnet

  plugin :association_dependencies, firewall_rules: :destroy, metric_destinations: :destroy
  dataset_module Authorization::Dataset
  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :initial_provisioning, :update_firewall_rules, :refresh_dns_record, :destroy

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :root_cert_key_1
    enc.column :root_cert_key_2
    enc.column :server_cert_key
  end

  def display_location
    LocationNameConverter.to_display_name(location)
  end

  def path
    "/location/#{display_location}/postgres/#{name}"
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{display_location}/postgres/#{name}"
  end

  def display_state
    return "unavailable" if representative_server&.strand&.label == "unavailable"
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

  def required_standby_count
    required_standby_count_map = {HaType::NONE => 0, HaType::ASYNC => 1, HaType::SYNC => 2}
    required_standby_count_map[ha_type]
  end

  def set_firewall_rules
    vm_firewall_rules = firewall_rules.map { {cidr: _1.cidr.to_s, port_range: Sequel.pg_range(5432..5432)} }
    vm_firewall_rules.push({cidr: "0.0.0.0/0", port_range: Sequel.pg_range(22..22)})
    vm_firewall_rules.push({cidr: "::/0", port_range: Sequel.pg_range(22..22)})
    private_subnet.firewalls.first.replace_firewall_rules(vm_firewall_rules)
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

  def self.redacted_columns
    super + [:root_cert_1, :root_cert_2, :server_cert]
  end
end
