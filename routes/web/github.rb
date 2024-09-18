# frozen_string_literal: true

class CloverWeb
  hash_branch("github") do |r|
    r.get "callback" do
      oauth_code = r.params["code"]
      installation_id = r.params["installation_id"]
      setup_action = r.params["setup_action"]
      code_response = Github.oauth_client.exchange_code_for_token(oauth_code)

      if (installation = GithubInstallation[installation_id: installation_id])
        Authorization.authorize(@current_user.id, "Project:github", installation.project.id)
        flash["notice"] = "GitHub runner integration is already enabled for #{installation.project.name} project."
        r.redirect "#{installation.project.path}/github"
      end

      unless (project = Project[session.delete("github_installation_project_id")])
        flash["error"] = "You should initiate the GitHub App installation request from the project's GitHub runner integration page."
        r.redirect "/dashboard"
      end

      Authorization.authorize(@current_user.id, "Project:github", project.id)

      if setup_action == "request"
        flash["notice"] = "The GitHub App installation request is awaiting approval from the GitHub organization's administrator. As GitHub will redirect your admin back to the Ubicloud console, the admin needs to have an Ubicloud account with the necessary permissions to finalize the installation. Please invite the admin to your project if they don't have an account yet."
        r.redirect "#{project.path}/user"
      end

      unless (access_token = code_response[:access_token])
        flash["error"] = "GitHub App installation failed. For any questions or assistance, reach out to our team at support@ubicloud.com"
        r.redirect "#{project.path}/github"
      end

      unless (installation_response = Octokit::Client.new(access_token: access_token).get("/user/installations")[:installations].find { _1[:id].to_s == installation_id })
        flash["error"] = "GitHub App installation failed. For any questions or assistance, reach out to our team at support@ubicloud.com"
        r.redirect "#{project.path}/github"
      end

      if @current_user.suspended_at
        flash["error"] = "GitHub runner integration is not allowed for suspended accounts."
        r.redirect "#{project.path}/dashboard"
      end

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
