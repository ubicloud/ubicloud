# frozen_string_literal: true

class UbiCli
  on("pg", "ember", "list") do
    desc "List PostgreSQL embers"

    key = :pg_ember_list

    options("ubi pg ember list [options]", key:) do
      on("-N", "--no-headers", "do not show headers")
    end

    run do |opts|
      opts = opts[key]
      items = sdk.postgres.embers
      response(format_rows(%i[id name location state pg_version], items, headers: opts[:"no-headers"] != false))
    end
  end
end
