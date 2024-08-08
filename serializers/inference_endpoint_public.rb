# frozen_string_literal: true

class Serializers::InferenceEndpointPublic < Serializers::Base
  def self.serialize_internal(ie, options = {})
    base = {
      name: ie.name,
      base_url: "https://#{ie.load_balancer.hostname}/v1",
      location: ie.display_location,
      model_name: ie.model_name
    }

    if options[:include_path]
      base[:path] = ie.path
    end
    base
  end
end
