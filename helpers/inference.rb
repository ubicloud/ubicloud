# frozen_string_literal: true

class Clover
  def inference_endpoint_list
    dataset_private = dataset_authorize(@project.inference_endpoints_dataset, "InferenceEndpoint:view")
    dataset_public = InferenceEndpoint.where(is_public: true)

    dataset = dataset_private.union(dataset_public)
    dataset = dataset.where(visible: true)

    Serializers::InferenceEndpoint.serialize(dataset.all)
  end

  def inference_token_list
    dataset = dataset_authorize(@project.api_keys_dataset.where(used_for: "inference_endpoint"), "InferenceToken:view")
    dataset = dataset.where(is_valid: true)
    Serializers::InferenceToken.serialize(dataset.all)
  end
end
