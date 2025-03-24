# frozen_string_literal: true

class Serializers::InferenceEndpoint < Serializers::Base
  def self.serialize_internal(ie, options = {})
    {
      id: ie.ubid,
      name: ie.name,
      model_name: ie.model_name,
      tags: ie.tags,
      url: "#{ie.load_balancer.health_check_protocol}://#{ie.load_balancer.hostname}",
      is_public: ie.is_public,
      location: ie.display_location,
      input_price_million_tokens: (BillingRate.from_resource_properties(
        "InferenceTokens", "#{ie.model_name}-input", "global"
      )["unit_price"] * 1000000).round(2),
      output_price_million_tokens: (BillingRate.from_resource_properties(
        "InferenceTokens", "#{ie.model_name}-output", "global"
      )["unit_price"] * 1000000).round(2),
      path: ie.path
    }
  end
end
