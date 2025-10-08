# frozen_string_literal: true

UbiCli.on("gh", "installation").run_on("list-repositories") do
  desc "List GitHub repositories for an installation"

  key = :github_repositories_list

  options("ubi gh installation installation-name list-repositories [options]", key:) do
    on("-N", "--no-headers", "do not show headers")
  end

  run do |opts|
    response(format_rows(%i[id name], @installation.repositories, headers: opts[key][:"no-headers"] != false))
  end
end
