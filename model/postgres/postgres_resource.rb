# frozen_string_literal: true

require_relative "../../model"

class PostgresResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  one_to_many :active_billing_records, class: :BillingRecord, key: :resource_id do |ds| ds.active end
  one_to_one :server, class: PostgresServer, key: :resource_id
  one_through_one :timeline, class: PostgresTimeline, join_table: :postgres_server, left_key: :resource_id, right_key: :timeline_id

  include ResourceMethods

  def self.redacted_columns
    super + [:root_cert_1, :root_cert_2, :server_cert]
  end

  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :root_cert_key_1
    enc.column :root_cert_key_2
    enc.column :server_cert_key
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/postgres/#{server_name}"
  end

  def hostname
    if Config.postgres_service_hostname
      "#{server_name}.#{Config.postgres_service_hostname}"
    else
      server&.vm&.ephemeral_net4&.to_s
    end
  end

  def connection_string
    URI::Generic.build2(scheme: "postgres", userinfo: "postgres:#{URI.encode_uri_component(superuser_password)}", host: hostname).to_s if hostname
  end
end
