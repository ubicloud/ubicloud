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

  def self.from_resource_properties(resource_type, resource_family, location, byoc = false, active_at = Time.now)
    rates.select {
      it["resource_type"] == resource_type && it["resource_family"] == resource_family && it["location"] == location && it["byoc"] == byoc && it["active_from"] < active_at
    }.max_by { it["active_from"] }
  end

  def self.unit_price_from_resource_properties(resource_type, resource_family, location, byoc = false, active_at = Time.now)
    from_resource_properties(resource_type, resource_family, location, byoc, active_at)&.[]("unit_price")&.to_f
  end

  def self.from_resource_type(resource_type)
    rates.select {
      it["resource_type"] == resource_type
    }
  end

  def self.from_id(billing_rate_id)
    rates.find { it["id"] == billing_rate_id }
  end

  def self.line_item_description(resource_type, resource_family, amount)
    case resource_type
    when "VmCores"
      "#{resource_family}-#{(amount * 2).to_i} Virtual Machine"
    when "VmVCpu"
      "#{resource_family}-#{amount.to_i} Virtual Machine"
    when "VmStorage"
      "#{amount.to_i} GiB Storage for Virtual Machine"
    when "IPAddress"
      "#{resource_family} Address"
    when "PostgresCores"
      "#{resource_family}-#{(amount * 2).to_i} backed PostgreSQL Database"
    when "PostgresVCpu"
      "#{resource_family}-#{amount.to_i} backed PostgreSQL Database"
    when "PostgresStandbyCores"
      "#{resource_family}-#{(amount * 2).to_i} backed PostgreSQL Database (HA Standby)"
    when "PostgresStandbyVCpu"
      "#{resource_family}-#{amount.to_i} backed PostgreSQL Database (HA Standby)"
    when "PostgresStorage"
      "#{amount.to_i} GiB Storage for PostgreSQL Database"
    when "PostgresStandbyStorage"
      "#{amount.to_i} GiB Storage for PostgreSQL Database (HA Standby)"
    when "GitHubRunnerMinutes"
      "#{resource_family} GitHub Runner"
    when "GitHubRunnerConcurrency"
      "Additional GitHub Runner Concurrency"
    when "GitHubCacheStorage"
      "#{amount.to_i} GiB Storage for GitHub Cache"
    when "InferenceTokens"
      "#{resource_family} Inference Tokens"
    when "Gpu"
      "#{amount.to_i}x #{PciDevice.device_name(resource_family)}"
    when "KubernetesControlPlaneVCpu"
      "#{resource_family}-#{amount.to_i} backed Kubernetes Control Plane Node"
    when "KubernetesWorkerVCpu"
      "#{resource_family}-#{amount.to_i} backed Kubernetes Worker Node"
    when "KubernetesWorkerStorage"
      "#{amount.to_i} GiB Storage for Kubernetes Worker Node"
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
