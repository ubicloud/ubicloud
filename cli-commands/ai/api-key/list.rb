# frozen_string_literal: true

UbiCli.on("ai", "api-key", "list") do
  desc "List inference api keys"

  key = :api_key_list

  options("ubi ai api-key list [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    opts = opts[key]
    items = sdk.inference_api_key.list
    response(format_rows(%i[id key], items, headers: opts[:"no-headers"] != false))
  end
end
