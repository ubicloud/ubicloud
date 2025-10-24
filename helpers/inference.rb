# frozen_string_literal: true

class Clover
  def visible_capable_models(dataset)
    dataset
      .where(Sequel.|([:visible],
        Sequel.pg_jsonb_op(:tags)["visible_projects"].contains([@project.id])))
      .where(Sequel.pg_jsonb_op(:tags).get_text("capability") => ["Text Generation", "Embeddings"])
      .order(:model_name)
  end

  def inference_endpoint_ds
    dataset_private = dataset_authorize(@project.inference_endpoints_dataset, "InferenceEndpoint:view")
    dataset_public = InferenceEndpoint.where(is_public: true)

    dataset = dataset_private.union(dataset_public)
    dataset = visible_capable_models(dataset)
    dataset.eager(:load_balancer)
  end

  def inference_router_model_ds
    visible_capable_models(InferenceRouterModel)
      .eager_graph(inference_router_targets: {inference_router: :load_balancer})
      .exclude(inference_router_model_id: nil)
  end

  def inference_api_key_ds
    dataset = dataset_authorize(@project.api_keys_dataset.where(used_for: "inference_endpoint"), "InferenceApiKey:view")
    dataset = dataset.where(is_valid: true)
    dataset.order(:created_at)
  end
end
