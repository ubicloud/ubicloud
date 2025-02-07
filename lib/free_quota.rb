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
        hash[item["name"]] = item
      end
    end
    @free_quotas
  end

  def self.get_applicable_billing_rate_ids(free_quota)
    BillingRate.from_resource_type(free_quota["resource_type"]).map { _1["id"] }
  end

  def self.remaining_free_quota(name, project_id)
    free_quota = free_quotas[name]
    begin_time = get_begin_time
    tokens_used = BillingRecord.where(
      project_id: project_id,
      billing_rate_id: get_applicable_billing_rate_ids(free_quota)
    ).where {
      Sequel.pg_range(span).overlaps(Sequel.pg_range(begin_time...Time.now))
    }.sum(:free_quota_amount) || 0
    [0, free_quota["value"] - tokens_used].max
  end

  def self.display_unit(name)
    free_quotas[name]["display_unit"]
  end

  def self.get_free_quota_exhausted_projects(name)
    free_quota = free_quotas[name]
    begin_time = get_begin_time
    BillingRecord
      .where(billing_rate_id: get_applicable_billing_rate_ids(free_quota))
      .where { Sequel.pg_range(span).overlaps(Sequel.pg_range(begin_time...Time.now)) }
      .group(:project_id)
      .having { sum(:free_quota_amount) >= free_quota["value"] }
      .select(:project_id)
  end

  def self.get_begin_time
    Time.new(Time.now.year, Time.now.month, 1)
  end
end
