# frozen_string_literal: true

class Serializers::InferenceRouterModel < Serializers::Base
  def self.million_token_price(resource)
    (BillingRate.from_resource_properties("InferenceTokens", resource, "global")["unit_price"] * 1_000_000).round(2)
  end

  def self.serialize_internal(irm, options = {})
    load_balancer = irm.inference_router.load_balancer
    {
      id: irm.ubid,
      name: irm.model_name,
      model_name: irm.model_name,
      tags: irm.tags,
      url: "#{load_balancer.health_check_protocol}://#{load_balancer.hostname}",
      input_price_million_tokens: million_token_price(irm.prompt_billing_resource),
      output_price_million_tokens: million_token_price(irm.completion_billing_resource)
    }
  end
end
