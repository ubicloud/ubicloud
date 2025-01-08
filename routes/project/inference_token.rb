# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-token") do |r|
    r.web do
      r.get true do
        @inference_tokens = Serializers::InferenceToken.serialize(inference_token_ds.all)
        view "inference/token/index"
      end

      r.post true do
        authorize("InferenceToken:create", @project.id)
        it = DB.transaction { ApiKey.create_inference_token(@project) }
        flash["notice"] = "Created inference token with id #{it.ubid}"
        r.redirect "#{@project.path}/inference-token"
      end

      r.delete String do |ubid|
        if (it = ApiKey.from_ubid(ubid))
          authorize("InferenceToken:delete", it.id)
          it.destroy
          flash["notice"] = "Inference token deleted successfully"
        end
        204
      end
    end
  end
end
