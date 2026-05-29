# frozen_string_literal: true

class UbiCli
  on("ai", "api-key", "create") do
    desc "Create an inference API key"

    banner "ubi ai api-key create"

    run do
      iak = sdk.inference_api_key.create
      response("Created inference API key with id:#{iak.id} key:#{iak.key}")
    end
  end
end
