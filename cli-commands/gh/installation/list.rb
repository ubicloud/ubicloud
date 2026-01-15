# frozen_string_literal: true

UbiCli.on("gh", "installation", "list") do
  desc "List GitHub installations"

  key = :github_installations_list

  options("ubi gh installation list [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    response(format_rows(%i[id name], sdk.github_installation.list, headers: opts[key][:"no-headers"] != false))
  end
end
