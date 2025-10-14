# frozen_string_literal: true

require_relative "../model"

require "pagerduty"
require "openssl"

class Page < Sequel::Model
  dataset_module do
    where :active, resolved_at: nil

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
    pagerduty_client
    super
  end
  # :nocov:

  def self.pagerduty_client
    @pagerduty_client ||= Pagerduty.build(integration_key: Config.pagerduty_key, api_version: 2)
  end

  plugin SemaphoreMethods, :resolve
  plugin ResourceMethods

  def pagerduty_client
    self.class.pagerduty_client
  end

  def trigger
    return unless Config.pagerduty_key

    links = [{href: "https://admin.ubicloud.com/model/Page/#{ubid}", text: "Admin Page"}]
    details.fetch("related_resources", []).each do |ubid|
      links << {href: Config.pagerduty_log_link.gsub("<ubid>", ubid), text: "View #{ubid} Logs"} if Config.pagerduty_log_link
    end

    pagerduty_incident.trigger(summary:, severity:, source: "clover", custom_details: details, links:)
  end

  def resolve
    this.update(resolved_at: Sequel::CURRENT_TIMESTAMP)

    return unless Config.pagerduty_key

    pagerduty_incident.resolve
  end

  def self.generate_tag(*tag_parts)
    tag_parts.join("-")
  end

  def self.from_tag_parts(*tag_parts)
    tag = Page.generate_tag(tag_parts)
    Page.active.where(tag: tag).first
  end

  private

  def pagerduty_incident
    pagerduty_client.incident(OpenSSL::HMAC.hexdigest("SHA256", "ubicloud-page-key", tag))
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
