# frozen_string_literal: true

class Serializers::PostgresUpgrade < Serializers::Base
  def self.serialize_internal(postgres_resource, options = {})
    {
      current_version: postgres_resource.version,
      target_version: postgres_resource.target_version,
      upgrade_status: postgres_resource.upgrade_status
    }
  end
end
