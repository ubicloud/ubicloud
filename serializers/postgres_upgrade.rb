# frozen_string_literal: true

class Serializers::PostgresUpgrade < Serializers::Base
  def self.serialize_internal(postgres_resource, options = {})
    failure = postgres_resource.upgrade_failure
    logs_params = postgres_resource.upgrade_failure_logs_params(failure:)
    {
      current_version: postgres_resource.version,
      target_version: postgres_resource.target_version,
      upgrade_status: postgres_resource.upgrade_status,
      upgrade_stage: postgres_resource.upgrade_stage,
      upgrade_error: failure["upgrade_error"],
      upgrade_error_details: failure["upgrade_error_details"] || [],
      upgrade_failed_at: postgres_resource.upgrade_failed_at(failure:)&.utc&.iso8601,
      upgrade_logs_start: logs_params[:start],
      upgrade_logs_end: logs_params[:end],
    }
  end
end
