# frozen_string_literal: true

class Serializers::PostgresLogDestination < Serializers::Base
  def self.serialize_internal(ld, options = {})
    {
      id: ld.ubid,
      name: ld.name,
      type: ld.type,
      url: ld.url,
    }
  end
end
