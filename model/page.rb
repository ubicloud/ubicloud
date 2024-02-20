# frozen_string_literal: true

require_relative "../model"

require "pagerduty"
require "openssl"

class Page < Sequel::Model
  dataset_module do
    def active
      where(resolved_at: nil)
    end
  end

  include SemaphoreMethods
  include ResourceMethods
  semaphore :resolve

  def pagerduty_client
    @@pagerduty_client ||= Pagerduty.build(integration_key: Config.pagerduty_key, api_version: 2)
  end

  def trigger
    return unless Config.pagerduty_key

    links = []
    details.fetch("related_resources", []).each do |ubid|
      links << {href: Config.pagerduty_log_link.gsub("<ubid>", ubid), text: "View #{ubid} Logs"} if Config.pagerduty_log_link
    end

    incident = pagerduty_client.incident(OpenSSL::HMAC.hexdigest("SHA256", "ubicloud-page-key", tag))
    incident.trigger(summary: summary, severity: severity, source: "clover", custom_details: details, links: links)
  end

  def resolve
    update(resolved_at: Time.now)

    return unless Config.pagerduty_key

    incident = pagerduty_client.incident(OpenSSL::HMAC.hexdigest("SHA256", "ubicloud-page-key", tag))
    incident.resolve
  end

  def self.generate_tag(*tag_parts)
    tag_parts.join("-")
  end

  def self.from_tag_parts(*tag_parts)
    tag = Page.generate_tag(tag_parts)
    Page.active.where(tag: tag).first
  end
end
