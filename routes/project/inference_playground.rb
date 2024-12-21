# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-playground") do |r|
    r.on web? do
      next unless @project.get_ff_inference_ui

      r.get true do
        @inference_endpoints = Serializers::InferenceEndpoint.serialize(inference_endpoint_ds.reject { _1.model_type == :embedding })
        @inference_tokens = Serializers::InferenceToken.serialize(inference_token_ds.all)
        view "inference/endpoint/playground"
      end
    end
  end
end
