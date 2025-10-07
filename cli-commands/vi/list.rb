# frozen_string_literal: true

UbiCli.on("vi", "list") do
  desc "List virtual machine init scripts"

  key = :vm_init_script_list

  options("ubi vi list [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    opts = opts[key]
    items = sdk.vm_init_script.list
    response(format_rows(%i[id name], items, headers: opts[:"no-headers"] != false))
  end
end
