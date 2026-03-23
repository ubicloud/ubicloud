# frozen_string_literal: true

class Serializers::BillingResource < Serializers::Base
  def self.serialize_internal(br, options = {})
    {
      project_id: UBID.to_ubid(br.project_id),
      resource_id: UBID.to_ubid(br.resource_id),
      resource_name: br.resource_name,
      resource_tags: br.resource_tags
    }
  end
end
