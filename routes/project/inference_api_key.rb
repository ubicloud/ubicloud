# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "inference-api-key") do |r|
    r.is do
      r.get do
        @inference_api_keys = inference_api_key_ds.all

        if web?
          @remaining_free_quota = FreeQuota.remaining_free_quota("inference-tokens", @project.id)
          @free_quota_unit = "inference tokens"
          @has_valid_payment_method = @project.has_valid_payment_method?
          view "inference/api_key/index"
        else
          {items: @inference_api_keys.map { {id: it.ubid, key: it.key} }}
        end
      end

      r.post do
        authorize("InferenceApiKey:create", @project.id)
        iak = nil
        DB.transaction do
          iak = ApiKey.create_inference_api_key(@project)
          audit_log(iak, "create")
        end

        if web?
          flash["notice"] = "Created Inference API Key with id #{iak.ubid}. It may take a few minutes to sync."
          r.redirect "#{@project.path}/inference-api-key"
        else
          {id: iak.ubid, key: iak.key}
        end
      end
    end

    r.is :ubid_uuid do |id|
      iak = inference_api_key_ds.with_pk(id)

      r.get api? do
        if iak
          {id: iak.ubid, key: iak.key}
        end
      end

      r.delete do
        if iak
          authorize("InferenceApiKey:delete", iak.id)
          DB.transaction do
            iak.destroy
            audit_log(iak, "destroy")
          end
          flash["notice"] = "Inference API Key deleted successfully" if web?
        end
        204
      end
    end
  end
end
