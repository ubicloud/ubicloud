# frozen_string_literal: true

require_relative "../model"

require "openssl"

class Page < Sequel::Model
  class Client
    if Config.pagerduty_key
      require "pagerduty"

      def initialize
        @client = Pagerduty.build(integration_key: Config.pagerduty_key, api_version: 2)
      end

      def trigger(tag, summary:, severity:, details:, links:)
        incident(tag).trigger(summary:, severity:, source: "clover", custom_details: details, links:)
      end

      def resolve(tag)
        incident(tag).resolve
      end

      private

      def incident(tag)
        @client.incident(OpenSSL::HMAC.hexdigest("SHA256", "ubicloud-page-key", tag))
      end
    elsif Config.incidentio_key
      require "excon"

      def trigger(tag, summary:, severity:, details:, links:)
        metadata = (details || {}).merge({severity:})
        link, *links = links
        metadata[:links] = links unless links.empty?
        body = {
          deduplication_key: deduplication_key(tag),
          status: "firing",
          title: summary,
          source_url: link&.[](:href),
          metadata:
        }.to_json
        Excon.post(uri, body:, headers: {
          "Authorization" => "Bearer #{Config.incidentio_key}",
          "Content-Type" => "application/json"
        })
      end

      def resolve(tag, summary:)
        body = {
          deduplication_key: deduplication_key(tag),
          title: summary,
          status: "resolved"
        }.to_json
        Excon.post(uri, body:, headers: {
          "Authorization" => "Bearer #{Config.incidentio_key}",
          "Content-Type" => "application/json"
        })
      end

      private

      def uri
        "https://api.incident.io/v2/alert_events/http/#{Config.incidentio_alert_source_config_id}"
      end

      def deduplication_key(tag)
        OpenSSL::HMAC.hexdigest("SHA256", "ubicloud-page-key", tag)
      end
    else
      def trigger(tag, **kwargs)
        kwargs[:tag] = tag
        Clog.emit("page triggered", {page_triggered: kwargs})
      end

      def resolve(tag)
        Clog.emit("page resolved", {page_resolved: {tag:}})
      end
    end
  end

  dataset_module do
    def group_by_vm_host
      pages = all
      related_resources = pages.flat_map { it.details["related_resources"] }.compact.to_h { [UBID.to_uuid(it), nil] }
      related_resources = UBID.resolve_map(related_resources, assume_et_is_api_key: false)
      related_resources.compact!
      # ubid => VmHost ubid
      host_map = {}
      # Vm id => ubid
      vm_id_map = {}

      related_resources.transform_values do
        case it
        when VmHost
          host_map[it.ubid] = it.ubid
        when Vm, VmHostSlice, VhostBlockBackend, StorageDevice, SpdkInstallation, PciDevice
          host_map[it.ubid] = UBID.from_uuidish(it.vm_host_id).to_s if it.vm_host_id
        when VmStorageVolume, VictoriaMetricsServer, Nic, MinioServer, GithubRunner, PostgresServer, InferenceEndpointReplica, InferenceRouterReplica
          (vm_id_map[it.vm_id] ||= []) << it.ubid if it.vm_id
        end
      end

      # Vm id => VmHost ubid
      vm_to_vm_host_map = Vm
        .where(id: vm_id_map.keys)
        .to_hash(:id, :vm_host_id)
        .compact
        .transform_values! { UBID.from_uuidish(it).to_s }

      vm_id_map.each do |vm_id, ubids|
        ubids.each do |ubid|
          host_map[ubid] = vm_to_vm_host_map[vm_id]
        end
      end

      grouped_pages = {}
      pages.each do |page|
        vm_host_ubid = nil
        page.details["related_resources"]&.find { vm_host_ubid = host_map[it] }
        (grouped_pages[vm_host_ubid] ||= []) << page
      end

      grouped_pages
    end
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

  private

  def incident
    client.incident(OpenSSL::HMAC.hexdigest("SHA256", "ubicloud-page-key", tag))
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
