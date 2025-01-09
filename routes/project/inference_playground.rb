# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-playground") do |r|
    r.get web? do
      @inference_endpoints = Serializers::InferenceEndpoint.serialize(inference_endpoint_ds.where(Sequel.pg_jsonb_op(:tags).get_text("capability") => "Text Generation"))
      @inference_api_keys = Serializers::InferenceApiKey.serialize(inference_api_key_ds.all)
      view "inference/endpoint/playground"
    end
  end
end
