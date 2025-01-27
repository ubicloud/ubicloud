# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-api-key") do |r|
    r.web do
      r.get true do
        @inference_api_keys = Serializers::InferenceApiKey.serialize(inference_api_key_ds.all)
        @has_free_inference_tokens = @project.has_free_inference_tokens?
        view "inference/api_key/index"
      end

      r.post true do
        authorize("InferenceApiKey:create", @project.id)
        iak = DB.transaction { ApiKey.create_inference_api_key(@project) }
        flash["notice"] = "Created Inference API Key with id #{iak.ubid}"
        r.redirect "#{@project.path}/inference-api-key"
      end

      r.delete String do |ubid|
        if (iak = inference_api_key_ds.with_pk(UBID.to_uuid(ubid)))
          authorize("InferenceApiKey:delete", iak.id)
          iak.destroy
          flash["notice"] = "Inference API Key deleted successfully"
        end
        204
      end
    end
  end
end
