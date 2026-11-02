# frozen_string_literal: true

class Serializers::PostgresMetricDestination < Serializers::Base
  def self.serialize_internal(md, options = {})
    {
      id: md.ubid,
      auth_methods: md.auth_methods,
      username: md.username,
      url: md.url,
    }
  end
end
