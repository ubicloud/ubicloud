# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "github") do |r|
    r.on web? do
      unless Config.github_app_name
        response.status = 501
        next "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
      end

      authorize("Project:github", @project.id)

      r.get true do
        if @project.github_installations.empty?
          r.redirect "#{@project.path}/github/setting"
        end
        r.redirect "#{@project.path}/github/runner"
      end

      r.get "runner" do
        @runners = Serializers::GithubRunner.serialize(@project.github_runners_dataset.eager(:vm, :strand).reverse(:created_at).all)

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

        r.on String do |installation_id|
          next unless (installation = GithubInstallation.from_ubid(installation_id))

          r.post true do
            cache_enabled = r.params["cache_enabled"] == "true"
            installation.update(cache_enabled: cache_enabled)
            flash["notice"] = "Ubicloud cache is #{cache_enabled ? "enabled" : "disabled"} for the installation #{installation.name}."

            r.redirect "#{@project.path}/github/setting"
          end
        end
      end

      r.on "cache" do
        r.get true do
          repository_id_q = @project.github_installations_dataset.join(:github_repository, installation_id: :id).select(Sequel[:github_repository][:id])
          entries = GithubCacheEntry.where(repository_id: repository_id_q).exclude(committed_at: nil).eager(:repository).reverse(:created_at).all
          @entries_by_repo = Serializers::GithubCacheEntry.serialize(entries).group_by { _1[:repository][:id] }
          @quota_per_repo = "#{@project.effective_quota_value("GithubRunnerCacheStorage")} GB"

          view "github/cache"
        end

        r.is String do |entry_ubid|
          next unless (entry = GithubCacheEntry.from_ubid(entry_ubid))

          r.delete true do
            entry.destroy
            flash["notice"] = "Cache '#{entry.key}' deleted."
            204
          end
        end
      end
    end
  end
end
