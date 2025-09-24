# frozen_string_literal: true

class Serializers::PostgresUpgrade < Serializers::Base
  def self.serialize_internal(postgres_resource, options = {})
    {
      current_version: postgres_resource.current_version,
      desired_version: postgres_resource.version,
      upgrade_status: postgres_resource.upgrade_status,
      upgrade_progress: postgres_resource.upgrade_progress
    }
  end
end
