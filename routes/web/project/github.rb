# frozen_string_literal: true

class CloverWeb
  CloverBase.run_on_all_locations :get_github_runners do |project|
    # Ordering is problematic
    project.github_installations_dataset.eager(runners: [:vm, :strand]).flat_map(&:runners).sort_by(&:created_at).reverse
  end
  hash_branch(:project_prefix, "github") do |r|
    unless Config.github_app_name
      response.status = 501
      return "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
    end

    Authorization.authorize(@current_user.id, "Project:github", @project.id)

    r.get true do
      @installations = Serializers::Web::GithubInstallation.serialize(@project.github_installations)
      @runners = Serializers::Web::GithubRunner.serialize(get_github_runners(@project))
      @has_valid_payment_method = @project.has_valid_payment_method?

      view "project/github"
    end

    r.on "installation" do
      r.get "create" do
        unless @project.has_valid_payment_method?
          fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"})
        end
        session[:github_installation_project_id] = @project.id

        r.redirect "https://github.com/apps/#{Config.github_app_name}/installations/new", 302
      end
    end
  end
end
