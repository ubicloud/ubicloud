# frozen_string_literal: true

class UbiCli
  on("gh", "connect") do
    desc "Connect a GitHub account to the project"

    key = :gh_connect

    options("ubi gh connect [options]", key:) do
      on("--confirm=code", "code shown after installing the GitHub App")
    end

    run do |opts|
      if (code = opts[key][:confirm] || opts[:confirm])
        installation = sdk.github_installation.create(code:)
        body = ["Connected GitHub installation ", installation.name, " to the project\n"]
        unless installation[:has_valid_payment_method]
          body << "\nThe project doesn't have a valid payment method. GitHub Actions jobs don't start until you add one:\n\n"
          body << Config.base_url << "/project/" << project_ubid << "/billing\n"
        end
        response(body)
      else
        url = sdk.github_installation.connect_url
        response(<<~END, headers: {"ubi-confirm" => "Code"})
          Open the following URL in your browser to install the Ubicloud GitHub App:

          #{url}

          After you install the app, GitHub redirects you to a Ubicloud page that shows a code.
          Enter the code below, or run: ubi gh connect --confirm=CODE
        END
      end
    end
  end
end
