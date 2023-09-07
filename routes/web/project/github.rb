# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "github") do |r|
    unless Config.github_app_name
      response.status = 501
      return "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
    end

    Authorization.authorize(@current_user.id, "Project:github", @project.id)

    r.get true do
      @installations = Serializers::Web::GithubInstallation.serialize(@project.github_installations)
      @runners = Serializers::Web::GithubRunner.serialize(@project.github_installations_dataset.eager(runners: :vm).flat_map(&:runners).sort_by(&:created_at).reverse)

      view "project/github"
    end

    r.on "installation" do
      r.get "create" do
        session[:github_installation_project_id] = @project.id

        r.redirect "https://github.com/apps/#{Config.github_app_name}/installations/new", 302
      end
    end
  end
end
