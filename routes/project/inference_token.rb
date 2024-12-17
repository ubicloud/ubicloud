# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-token") do |r|
    r.web do
      next unless @project.get_ff_inference_ui

      r.get true do
        dataset = dataset_authorize(@project.api_keys_dataset.where(used_for: "inference_endpoint"), "InferenceToken:view")
        dataset = dataset.where(is_valid: true)
        dataset = dataset.order(:created_at)
        @inference_tokens = Serializers::InferenceToken.serialize(dataset.all)
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
