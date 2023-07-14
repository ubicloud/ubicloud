# frozen_string_literal: true

require_relative "../model"

class Page < Sequel::Model
  dataset_module do
    def active
      where(resolved_at: nil)
    end
  end

  def initialize
    #@@pagerduty ||= Pagerduty.build(integration_key: Config.pagerduty_key, api_version: 2) if Config.pagerduty_key
  end

  def after_create
    #@@pagerduty&.trigger(incident_key: incident_key, summary: summary, severity: "error")
  end

  def resolve
    @resolved_at = Time.now

    #@@pagerduty&.incident(incident_key)&.resolve
  end
end
