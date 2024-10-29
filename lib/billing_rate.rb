# frozen_string_literal: true

require "yaml"

class BillingRate
  # :nocov:
  def self.freeze
    rates
    super
  end
  # :nocov:

  def self.rates
    @rates ||= YAML.load_file("config/billing_rates.yml", permitted_classes: [Time])
  end

  def self.from_resource_properties(resource_type, resource_family, location, active_at = Time.now)
    rates.select {
      _1["resource_type"] == resource_type && _1["resource_family"] == resource_family && _1["location"] == location && _1["active_from"] < active_at
    }.max_by { _1["active_from"] }
  end

  def self.from_id(billing_rate_id)
    rates.find { _1["id"] == billing_rate_id }
  end

  def self.line_item_description(resource_type, resource_family, amount)
    case resource_type
    when "VmCores"
      "#{resource_family}-#{(amount * 2).to_i} Virtual Machine"
    when "VmStorage"
      "#{amount.to_i} GiB Storage for Virtual Machine"
    when "IPAddress"
      "#{resource_family} Address"
    when "PostgresCores"
      "#{resource_family}-#{(amount * 2).to_i} backed PostgreSQL Database"
    when "PostgresStandbyCores"
      "#{resource_family}-#{(amount * 2).to_i} backed PostgreSQL Database (HA Standby)"
    when "PostgresStorage"
      "#{amount.to_i} GiB Storage for PostgreSQL Database"
    when "PostgresStandbyStorage"
      "#{amount.to_i} GiB Storage for PostgreSQL Database (HA Standby)"
    when "GitHubRunnerMinutes"
      "#{resource_family} GitHub Runner"
    when "GitHubRunnerConcurrency"
      "Additional GitHub Runner Concurrency"
    when "InferenceTokens"
      "#{resource_family} Inference Tokens"
    else
      fail "BUG: Unknown resource type for line item description"
    end
  end

  def self.line_item_usage(resource_type, resource_family, amount, duration)
    case resource_type
    when "GitHubRunnerMinutes"
      "#{amount.to_i} minutes"
    when "InferenceTokens"
      "#{amount.to_i} tokens"
    else
      "#{duration} minutes"
    end
  end
end
