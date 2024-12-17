# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-endpoint") do |r|
    r.web do
      next unless @project.get_ff_inference_ui

      r.get true do
        dataset_private = dataset_authorize(@project.inference_endpoints_dataset, "InferenceEndpoint:view")
        dataset_public = InferenceEndpoint.where(is_public: true)

        dataset = dataset_private.union(dataset_public)
        dataset = dataset.where(visible: true)
        dataset = dataset.order(:model_name)
        dataset = dataset.eager(:load_balancer)

        @inference_endpoints = Serializers::InferenceEndpoint.serialize(dataset.all)
        view "inference/endpoint/index"
      end
    end
  end
end
