# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-api-key") do |r|
    r.web do
      r.get true do
        @inference_api_keys = Serializers::InferenceApiKey.serialize(inference_api_key_ds.all)
        view "inference/api_key/index"
      end

      r.post true do
        authorize("InferenceApiKey:create", @project.id)
        it = DB.transaction { ApiKey.create_inference_api_key(@project) }
        flash["notice"] = "Created Inference API Key with id #{it.ubid}"
        r.redirect "#{@project.path}/inference-api-key"
      end

      r.delete String do |ubid|
        if (it = inference_api_key_ds.with_pk(UBID.to_uuid(ubid)))
          authorize("InferenceApiKey:delete", it.id)
          it.destroy
          flash["notice"] = "Inference API Key deleted successfully"
        end
        204
      end
    end
  end
end
