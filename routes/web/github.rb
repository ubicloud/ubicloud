# frozen_string_literal: true

class CloverWeb
  hash_branch("github") do |r|
    r.get "callback" do
      oauth_code = r.params["code"]
      installation_id = r.params["installation_id"]

      code_response = Github.oauth_client.exchange_code_for_token(oauth_code)

      unless (access_token = code_response[:access_token]) &&
          (installation_response = Octokit::Client.new(access_token: access_token).get("/user/installations")[:installations].find { _1[:id].to_s == installation_id })
        flash["error"] = "GitHub App installation failed."
        r.redirect "/dashboard"
      end

      if (installation = GithubInstallation[installation_id: installation_id])
        Authorization.authorize(@current_user.id, "Project:github", installation.project.id)
        flash["notice"] = "GitHub runner integration is already enabled for #{installation.project.name} project."
        r.redirect "#{installation.project.path}/github"
      end

      unless (project = Project[session.delete("github_installation_project_id")])
        flash["error"] = "Install GitHub App from project's 'GitHub Runners' page."
        r.redirect "/dashboard"
      end

      if project.accounts.any? { !_1.suspended_at.nil? }
        flash["error"] = "GitHub runner integration is not allowed for suspended accounts."
        r.redirect "/dashboard"
      end

      Authorization.authorize(@current_user.id, "Project:github", project.id)

      GithubInstallation.create_with_id(
        installation_id: installation_id,
        name: installation_response[:account][:login] || installation_response[:account][:name],
        type: installation_response[:account][:type],
        project_id: project.id
      )

      flash["notice"] = "GitHub runner integration is enabled for #{project.name} project."
      r.redirect "#{project.path}/github"
    end
  end
end
