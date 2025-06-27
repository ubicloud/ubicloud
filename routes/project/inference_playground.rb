# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-playground") do |r|
    r.get web? do
      inference_endpoints = Serializers::InferenceEndpoint.serialize(inference_endpoint_ds.eager(:location).where(Sequel.pg_jsonb_op(:tags).get_text("capability") => "Text Generation"))
      inference_router_models = Serializers::InferenceRouterModel.serialize(inference_router_model_ds.where(Sequel.pg_jsonb_op(:tags).get_text("capability") => "Text Generation").all)
      @inference_models = inference_router_models + inference_endpoints
      @inference_api_keys = Serializers::InferenceApiKey.serialize(inference_api_key_ds.all)
      @remaining_free_quota = FreeQuota.remaining_free_quota("inference-tokens", @project.id)
      @free_quota_unit = "inference tokens"
      @has_valid_payment_method = @project.has_valid_payment_method?
      view "inference/endpoint/playground"
    end
  end
end
