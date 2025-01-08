# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-endpoint") do |r|
    r.get web? do
      @inference_endpoints = Serializers::InferenceEndpoint.serialize(inference_endpoint_ds.all)
      view "inference/endpoint/index"
    end
  end
end
