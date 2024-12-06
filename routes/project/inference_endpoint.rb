# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-endpoint") do |r|
    unless @project.get_ff_inference_ui
      response.status = 404
      r.halt
    end

    r.get true do
      dataset_private = dataset_authorize(@project.inference_endpoints_dataset, "InferenceEndpoint:view")
      dataset_public = InferenceEndpoint.where(is_public: true)

      dataset = dataset_private.union(dataset_public)
      dataset = dataset.where(visible: true)

      @inference_endpoints = Serializers::InferenceEndpoint.serialize(dataset.all)
      view "inference/endpoint/index"
    end
  end
end
