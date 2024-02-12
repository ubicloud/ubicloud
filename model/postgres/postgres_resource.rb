# frozen_string_literal: true

require_relative "../../model"

class PostgresResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id do |ds| ds.active end
  many_to_one :parent, key: :parent_id, class: self
  one_to_one :server, class: PostgresServer, key: :resource_id
  one_through_one :timeline, class: PostgresTimeline, join_table: :postgres_server, left_key: :resource_id, right_key: :timeline_id
  one_to_many :firewall_rules, class: PostgresFirewallRule, key: :postgres_resource_id

  plugin :association_dependencies, firewall_rules: :destroy
  dataset_module Authorization::Dataset

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy, :update_firewall_rules

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :root_cert_key_1
    enc.column :root_cert_key_2
    enc.column :server_cert_key
  end

  def path
    "/location/#{location}/postgres/#{name}"
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/postgres/#{name}"
  end

  def display_state
    return "running" if ["wait", "refresh_certificates"].include?(strand.label)
    return "deleting" if destroy_set? || strand.label == "destroy"
    "creating"
  end

  def hostname
    if Prog::Postgres::PostgresResourceNexus.dns_zone
      "#{name}.#{Config.postgres_service_hostname}"
    else
      server&.vm&.ephemeral_net4&.to_s
    end
  end

  def connection_string
    URI::Generic.build2(scheme: "postgres", userinfo: "postgres:#{URI.encode_uri_component(superuser_password)}", host: hostname).to_s if hostname
  end

  def self.redacted_columns
    super + [:root_cert_1, :root_cert_2, :server_cert]
  end
end
