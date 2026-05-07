# frozen_string_literal: true

require_relative "../model"

require "openssl"
class Page < Sequel::Model
  class Client
    def initialize
      if Config.pagerduty_key
        require "pagerduty"
        @client = Pagerduty.build(integration_key: Config.pagerduty_key, api_version: 2)
      end
    end

    def trigger(tag, summary:, severity:, details:, links:)
      if Config.pagerduty_key
        pagerduty_incident(tag).trigger(summary:, severity:, source: "clover", custom_details: details, links:)
      elsif Config.incidentio_key
        metadata = (details || {}).merge({severity:})
        link, *links = links
        metadata[:links] = links unless links.empty?
        body = {
          deduplication_key: deduplication_key(tag),
          status: "firing",
          title: summary,
          source_url: link&.[](:href),
          metadata:,
        }.to_json
        Excon.post(incidentio_uri, body:, headers: {
          "Authorization" => "Bearer #{Config.incidentio_key}",
          "Content-Type" => "application/json",
        })
      else
        Clog.emit("page triggered", {page_triggered: {tag:, summary:, severity:, details:, links:}})
      end
    end

    def resolve(tag, summary:)
      if Config.pagerduty_key
        pagerduty_incident(tag).resolve
      elsif Config.incidentio_key
        body = {
          deduplication_key: deduplication_key(tag),
          status: "resolved",
          title: summary,
        }.to_json
        Excon.post(incidentio_uri, body:, headers: {
          "Authorization" => "Bearer #{Config.incidentio_key}",
          "Content-Type" => "application/json",
        })
      else
        Clog.emit("page resolved", {page_resolved: {tag:}})
      end
    end

    private

    def pagerduty_incident(tag)
      @client.incident(deduplication_key(tag))
    end

    def incidentio_uri
      "https://api.incident.io/v2/alert_events/http/#{Config.incidentio_alert_source_config_id}"
    end

    def deduplication_key(tag)
      OpenSSL::HMAC.hexdigest("SHA256", "ubicloud-page-key", tag)
    end
  end

  # Used by PageNexus to eager load appropriately.
  # Kept here as it is easier to keep in sync with root_resources directly below.
  EAGER_ROOT_RESOURCES = {}
  %w[VmStorageVolume
    VictoriaMetricsServer
    Nic
    MinioServer
    PostgresServer
    InferenceEndpointReplica
    InferenceRouterReplica
    GithubRunner].each do |name|
      EAGER_ROOT_RESOURCES[name] = :vm
    end
  EAGER_ROOT_RESOURCES["PostgresTimeline"] = :leader
  EAGER_ROOT_RESOURCES.freeze

  def self.root_resources(obj)
    ids = case obj
    when VmHost, GithubInstallation, PostgresResource
      [obj.id]
    when Vm, VmHostSlice, VhostBlockBackend, StorageDevice, SpdkInstallation, PciDevice
      [obj.vm_host_id]
    when VmStorageVolume, VictoriaMetricsServer, Nic, MinioServer, InferenceEndpointReplica, InferenceRouterReplica
      [obj.vm&.vm_host_id]
    when PostgresServer
      [obj.vm&.vm_host_id, obj.resource_id]
    when PostgresTimeline
      [*(root_resources(obj.leader) if obj.leader)]
    when GithubRunner
      [obj.installation_id, obj.vm&.vm_host_id]
    when GithubRepository
      [obj.installation_id]
    end

    ids&.compact!
    ids || [].freeze
  rescue => e
    Clog.emit("error determining root resource for page", {page_root_resource_error: Util.exception_to_hash(e, into: {object: obj})})
    [].freeze
  end

  # This cannot be covered, as the current coverage tests run without freezing models.
  # :nocov:
  def self.freeze
    client
    super
  end
  # :nocov:

  def self.client
    @client ||= Client.new
  end

  plugin SemaphoreMethods, :resolve, :retrigger
  plugin ResourceMethods

  def client
    self.class.client
  end

  def trigger
    links = [{href: "#{Config.admin_url}/model/Page/#{ubid}", text: "Admin Page"}]
    details.fetch("related_resources", []).each do |ubid|
      links << {href: Config.pagerduty_log_link.gsub("<ubid>", ubid), text: "View #{ubid} Logs"} if Config.pagerduty_log_link
    end

    client.trigger(tag, summary:, severity:, details:, links:)
  end

  def resolve
    this.update(resolved_at: Sequel::CURRENT_TIMESTAMP)

    client.resolve(tag, summary:)
  end

  def self.generate_tag(*tag_parts)
    tag_parts.join("-")
  end

  def self.from_tag_parts(*tag_parts)
    tag = Page.generate_tag(tag_parts)
    Page.where(tag:).first
  end

  SEVERITY_ORDER = {"info" => 0, "warning" => 1, "error" => 2, "critical" => 3}.freeze

  def self.severity_order(severity)
    SEVERITY_ORDER.fetch(severity)
  end
end

# Table: page
# Columns:
#  id          | uuid                     | PRIMARY KEY
#  created_at  | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  resolved_at | timestamp with time zone |
#  summary     | text                     |
#  tag         | text                     | NOT NULL
#  details     | jsonb                    | NOT NULL DEFAULT '{}'::jsonb
#  severity    | page_severity            | NOT NULL DEFAULT 'error'::page_severity
# Indexes:
#  page_pkey      | PRIMARY KEY btree (id)
#  page_tag_index | UNIQUE btree (tag) WHERE resolved_at IS NULL
# Referenced By:
#  page_root_resource | page_root_resource_page_id_fkey | (page_id) REFERENCES page(id) ON DELETE CASCADE
