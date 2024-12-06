# frozen_string_literal: true

class Serializers::InferenceToken < Serializers::Base
  def self.serialize_internal(it, options = {})
    {
      id: it.ubid,
      key: it.key,
      created_at: it.created_at,
      path: "/inference-token/#{it.ubid}"
    }
  end
end
