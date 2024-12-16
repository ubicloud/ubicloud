# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-endpoint") do |r|
    r.web do
      next unless @project.get_ff_inference_ui

      r.get true do
        @inference_endpoints = Serializers::InferenceEndpoint.serialize(inference_endpoint_ds.all)
        view "inference/endpoint/index"
      end
    end
  end
end
