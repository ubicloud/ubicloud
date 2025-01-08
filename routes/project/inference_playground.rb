# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-playground") do |r|
    r.get web? do
      @inference_endpoints = Serializers::InferenceEndpoint.serialize(inference_endpoint_ds.where(Sequel.pg_jsonb_op(:tags).get_text("capability") => "Text Generation"))
      @inference_tokens = Serializers::InferenceToken.serialize(inference_token_ds.all)
      view "inference/endpoint/playground"
    end
  end
end
