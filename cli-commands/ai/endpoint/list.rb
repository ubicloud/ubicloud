# frozen_string_literal: true

UbiCli.on("ai", "endpoint", "list") do
  desc "List inference endpoints"

  fields = %w[name display-name hf-model capability multimodal context-length url input-price output-price].freeze
  default_fields = %w[name capability multimodal context-length input-price output-price].freeze

  key = :endpoint_list

  options("ubi ai endpoint list [options]", key:) do
    on("-f", "--fields=fields", "show specific fields (comma separated)")
    on("-N", "--no-headers", "do not show headers")
  end
  help_option_values("Fields:", fields)

  run do |opts, command|
    opts = opts[key]
    items = sdk.inference_endpoint.list.map do |ie|
      price = ie[:price] || {}
      tags = ie[:tags] || {}
      {
        name: ie[:name],
        display_name: ie[:display_name],
        hf_model: tags[:hf_model],
        capability: tags[:capability],
        multimodal: tags[:multimodal],
        context_length: tags[:context_length],
        url: ie[:url],
        input_price: price[:per_million_prompt_tokens],
        output_price: price[:per_million_completion_tokens]
      }
    end
    given = opts[:fields]
    keys = underscore_keys(given ? check_fields(given, fields, "ai endpoint list -f option", command) : default_fields)
    response(format_rows(keys, items, headers: opts[:"no-headers"] != false))
  end
end
