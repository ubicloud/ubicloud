# frozen_string_literal: true

UbiCli.on("jw", "list") do
  desc "List JWT issuers"

  key = :jw_list

  options("ubi jw list [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    opts = opts[key]
    items = sdk.jwt_issuer.list
    response(format_rows(%i[id name issuer audience jwks_uri], items, headers: opts[:"no-headers"] != false))
  end
end
