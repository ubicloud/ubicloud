# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-token") do |r|
    unless @project.get_ff_inference_ui
      response.status = 404
      r.halt
    end

    r.get true do
      dataset = dataset_authorize(@project.api_keys_dataset.where(used_for: "inference_endpoint"), "InferenceToken:view")
      dataset = dataset.where(is_valid: true)
      @inference_tokens = Serializers::InferenceToken.serialize(dataset.all)
      view "inference/token/index"
    end

    r.on web? do
      r.post true do
        authorize("InferenceToken:create", @project.id)
        it = DB.transaction { ApiKey.create_inference_token(@project) }
        flash["notice"] = "Created inference token with id #{it.ubid}"
        r.redirect "#{@project.path}/inference-token"
      end

      r.delete do
        r.is String do |ubid|
          it = ApiKey.from_ubid(ubid)

          unless it.nil?
            authorize("InferenceToken:delete", it.id)
            it.destroy
            flash["notice"] = "Inference token deleted successfully"
          end

          204
        end
      end
    end
  end
end
