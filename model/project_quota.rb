#  frozen_string_literal: true

require_relative "../model"

class ProjectQuota < Sequel::Model
  unrestrict_primary_key

  # :nocov:
  def self.freeze
    default_quotas
    super
  end
  # :nocov:

  def self.default_quotas
    @default_quotas ||= YAML.load_file("config/default_quotas.yml").each_with_object({}) do |item, hash|
      hash[item["resource_type"]] = item
    end
  end
end

# Table: project_quota
# Primary Key: (project_id, quota_id)
# Columns:
#  project_id | uuid    |
#  quota_id   | uuid    |
#  value      | integer | NOT NULL
# Indexes:
#  project_quota_pkey | PRIMARY KEY btree (project_id, quota_id)
