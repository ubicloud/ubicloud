# frozen_string_literal: true

class Clover
  def inference_endpoint_ds
    dataset_private = dataset_authorize(@project.inference_endpoints_dataset, "InferenceEndpoint:view")
    dataset_public = InferenceEndpoint.where(is_public: true)

    dataset = dataset_private.union(dataset_public)
    dataset = dataset.where(visible: true)
    dataset = dataset.where(Sequel.pg_jsonb_op(:tags).get_text("capability") => ["Text Generation", "Embeddings"])
    dataset = dataset.order(:model_name)
    dataset.eager(:load_balancer)
  end

  def inference_token_ds
    dataset = dataset_authorize(@project.api_keys_dataset.where(used_for: "inference_endpoint"), "InferenceToken:view")
    dataset = dataset.where(is_valid: true)
    dataset.order(:created_at)
  end
end
