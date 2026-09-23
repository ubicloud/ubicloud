# frozen_string_literal: true

class UbiCli
  on("gh", "installation").run_on("list-runners") do
    desc "List active GitHub Actions runners for an installation"

    key = :github_runners_list

    options("ubi gh installation installation-name list-runners [options]", key:) do
      on("-N", "--no-headers", "do not show headers")
    end

    run do |opts|
      response(format_rows(%i[id repository_name label status created_at], @installation.runners, headers: opts[key][:"no-headers"] != false))
    end
  end
end
