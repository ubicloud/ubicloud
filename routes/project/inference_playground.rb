# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-playground") do |r|
    r.get web? do
      @inference_models = [inference_router_model_ds, inference_endpoint_ds.eager(:location)].flat_map do |ds|
        ds.where(Sequel.pg_jsonb_op(:tags).get_text("capability") => "Text Generation").all
      end

      @inference_api_keys = inference_api_key_ds.all
      @remaining_free_quota = FreeQuota.remaining_free_quota("inference-tokens", @project.id)
      @free_quota_unit = "inference tokens"
      @has_valid_payment_method = @project.has_valid_payment_method?
      view "inference/endpoint/playground"
    end
  end
end
