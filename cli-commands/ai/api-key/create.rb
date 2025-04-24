# frozen_string_literal: true

UbiCli.on("ai", "api-key", "create") do
  desc "Create an inference api key"

  banner "ubi ai api-key create"

  run do
    iak = sdk.inference_api_key.create
    response("Created inference api key with id:#{iak.id} key:#{iak.key}")
  end
end
