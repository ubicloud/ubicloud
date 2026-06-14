# frozen_string_literal: true

class UbiCli
  on("ss", "list") do
    desc "List secret stores"

    key = :secret_store_list

    options("ubi ss list [options]", key:) do
      on("-N", "--no-headers", "do not show headers")
    end

    run do |opts|
      opts = opts[key]
      items = sdk.secret_store.list
      response(format_rows(%i[id name], items, headers: opts[:"no-headers"] != false))
    end
  end
end
