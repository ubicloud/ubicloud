#  frozen_string_literal: true

require_relative "../model"

class ProjectQuota < Sequel::Model
  @@default_quotas = nil
  def self.default_quotas
    @@default_quotas ||= YAML.load_file("config/default_quotas.yml").each_with_object({}) do |item, hash|
      hash[item["resource_type"]] = item
    end
  end
end

ProjectQuota.unrestrict_primary_key
