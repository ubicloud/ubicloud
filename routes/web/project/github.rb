# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "github") do |r|
    unless Config.github_app_name
      response.status = 501
      return "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
    end

    Authorization.authorize(@current_user.id, "Project:github", @project.id)

    r.get true do
      if @project.github_installations.empty?
        r.redirect "#{@project.path}/github/setting"
      end
      r.redirect "#{@project.path}/github/runner"
    end

    r.get "runner" do
      @runners = Serializers::GithubRunner.serialize(@project.github_installations_dataset.eager(runners: [:vm, :strand]).flat_map(&:runners).sort_by(&:created_at).reverse)

      view "github/runner"
    end

    r.get "setting" do
      @has_valid_payment_method = @project.has_valid_payment_method?
      @installations = Serializers::GithubInstallation.serialize(@project.github_installations)

      view "github/setting"
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
