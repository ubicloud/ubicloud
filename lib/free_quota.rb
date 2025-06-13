# frozen_string_literal: true

require "yaml"

class FreeQuota
  # :nocov:
  def self.freeze
    free_quotas
    super
  end
  # :nocov:

  def self.free_quotas
    @free_quotas ||= begin
      quotas = YAML.load_file("config/free_quotas.yml")
      quotas.each_with_object({}) do |item, hash|
        item["billing_rate_ids"] = BillingRate.from_resource_type(item["resource_type"]).map { it["id"] }
        hash[item["name"]] = item
      end
    end
    @free_quotas
  end

  def self.remaining_free_quota(name, project_id)
    free_quota = free_quotas[name]
    used_amount = BillingRecord
      .where(project_id:, billing_rate_id: free_quota["billing_rate_ids"])
      .where_span(FreeQuota.begin_of_month, Time.now)
      .sum(:amount) || 0
    [0, free_quota["value"] - used_amount].max
  end

  def self.get_exhausted_projects(name)
    free_quota = free_quotas[name]
    BillingRecord
      .where(billing_rate_id: free_quota["billing_rate_ids"])
      .where_span(FreeQuota.begin_of_month, Time.now)
      .group(:project_id)
      .having { sum(:amount) >= free_quota["value"] }
      .select(:project_id)
  end

  def self.begin_of_month
    Time.new(Time.now.year, Time.now.month, 1)
  end
end
