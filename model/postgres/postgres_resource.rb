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

  plugin :association_dependencies, firewall_rules: :destroy
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
    return "running" if ["wait", "refresh_certificates"].include?(strand.label)
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
      sslrootcert: "/dat/16/data/ca.crt",
      sslcert: "/dat/16/data/server.crt",
      sslkey: "/dat/16/data/server.key",
      sslmode: "verify-full",
      application_name: application_name
    }.map { |k, v| "#{k}=#{v}" }.join("\\&")

    URI::Generic.build2(scheme: "postgres", userinfo: "ubi_replication", host: identity, query: query_parameters).to_s
  end

  def required_standby_count
    required_standby_count_map = {HaType::NONE => 0, HaType::ASYNC => 1, HaType::SYNC => 2}
    required_standby_count_map[ha_type]
  end

  module HaType
    NONE = "none"
    ASYNC = "async"
    SYNC = "sync"
  end

  def self.redacted_columns
    super + [:root_cert_1, :root_cert_2, :server_cert]
  end
end
