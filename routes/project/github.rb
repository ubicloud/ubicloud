# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "github") do |r|
    r.on web? do
      unless Config.github_app_name
        response.status = 501
        return "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
      end

      authorize("Project:github", @project.id)

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
        @installations = Serializers::GithubInstallation.serialize(@project.github_installations)

        view "github/setting"
      end

      r.on "installation" do
        r.get "create" do
          unless @project.has_valid_payment_method?
            flash["error"] = "Project doesn't have valid billing information"
            r.redirect "#{@project.path}/github"
          end
          session[:github_installation_project_id] = @project.id

          r.redirect "https://github.com/apps/#{Config.github_app_name}/installations/new", 302
        end
      end

      r.on "cache" do
        r.get true do
          repository_id_q = @project.github_installations_dataset.join(:github_repository, installation_id: :id).select(Sequel[:github_repository][:id])
          @entries = Serializers::GithubCacheEntry.serialize(GithubCacheEntry.where(repository_id: repository_id_q).exclude(committed_at: nil).eager(:repository).order(Sequel.desc(:created_at)).all)
          @total_usage = Serializers::GithubCacheEntry.humanize_size(@entries.filter_map { _1[:size] }.sum)
          @total_quota = "#{@project.effective_quota_value("GithubRunnerCacheStorage")} GB"

          view "github/cache"
        end

        r.is String do |entry_ubid|
          entry = GithubCacheEntry.from_ubid(entry_ubid)

          unless entry
            response.status = 404
            r.halt
          end

          r.delete true do
            entry.destroy
            flash["notice"] = "Cache '#{entry.key}' deleted."
            response.status = 204
            request.halt
          end
        end
      end
    end
  end
end
