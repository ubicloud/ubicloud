# frozen_string_literal: true

require_relative "../model"

require "pagerduty"

class Page < Sequel::Model
  dataset_module do
    def active
      where(resolved_at: nil)
    end
  end

  include SemaphoreMethods
  include ResourceMethods
  semaphore :resolve

  def self.ubid_type
    UBID::TYPE_PAGE
  end

  def pagerduty_client
    @@pagerduty_client ||= Pagerduty.build(integration_key: Config.pagerduty_key, api_version: 2)
  end

  def trigger
    return unless Config.pagerduty_key

    incident = pagerduty_client.incident(Digest::MD5.hexdigest(id))
    incident.trigger(summary: summary, severity: "error", source: "clover")
  end

  def resolve
    update(resolved_at: Time.now)

    return unless Config.pagerduty_key

    incident = pagerduty_client.incident(Digest::MD5.hexdigest(id))
    incident.resolve
  end
end
