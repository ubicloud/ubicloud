# frozen_string_literal: true

class Serializers::InferenceEndpointPrivate < Serializers::Base
  def self.serialize_internal(ie, options = {})
    base = {
      id: ie.ubid,
      name: ie.name,
      base_url: "https://#{ie.load_balancer.hostname}/v1",
      location: ie.display_location,
      model_name: ie.model_name,
      min_replicas: ie.min_replicas,
      max_replicas: ie.max_replicas,
      replicas: ie.replicas.count,
      state: ie.display_state
    }

    if options[:include_path]
      base[:path] = ie.path
    end
    base
  end
end
