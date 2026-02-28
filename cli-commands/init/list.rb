# frozen_string_literal: true

UbiCli.on("init", "list") do
  desc "List init scripts"

  key = :init_list

  options("ubi init list [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    opts = opts[key]
    items = sdk.init_script_tag.list

    # Format version as @N and size as human-readable
    items = items.map do |item|
      h = item.to_h
      h[:version] = "@#{h[:version]}"
      size = h[:size].to_i
      h[:size] = if size >= 1024
        "#{(size / 1024.0).round(1)}K"
      else
        "#{size}B"
      end
      h
    end

    response(format_rows(%i[name version id size created_at], items, headers: opts[:"no-headers"] != false))
  end
end
