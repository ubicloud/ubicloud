# frozen_string_literal: true

UbiCli.on("sk", "list") do
  desc "List SSH public keys"

  key = :ssh_public_key_list

  options("ubi sk list [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    opts = opts[key]
    items = sdk.ssh_public_key.list
    response(format_rows(%i[id name], items, headers: opts[:"no-headers"] != false))
  end
end
