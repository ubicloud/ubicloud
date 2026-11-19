# frozen_string_literal: true

class Serializers::PostgresUpgrade < Serializers::Base
  def self.serialize_internal(postgres_resource, options = {})
    {
      current_version: postgres_resource.version,
      target_version: postgres_resource.target_version,
      upgrade_status: postgres_resource.upgrade_status,
      upgrade_stage: postgres_resource.upgrade_stage,
      upgrade_failed_at: postgres_resource.upgrade_failed_at&.utc&.iso8601,
    }
  end
end
