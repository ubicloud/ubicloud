# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "github") do |r|
    r.web do
      unless Config.github_app_name
        response.status = 501
        response["content-type"] = "text/plain"
        next "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
      end

      authorize("Project:github", @project.id)

      r.get true do
        if (installation = @project.github_installations.first)
          r.redirect "#{@project.path}/github/#{installation.ubid}/runner"
        end
        view "github/index"
      end

      r.get "create" do
        unless @project.has_valid_payment_method?
          flash["error"] = "Project doesn't have valid billing information"
          r.redirect "#{@project.path}/github"
        end
        session[:github_installation_project_id] = @project.id

        r.redirect "https://github.com/apps/#{Config.github_app_name}/installations/new", 302
      end

      r.on String do |installation_ubid|
        next unless (@installation = GithubInstallation.from_ubid(installation_ubid)) && @installation.project_id == @project.id

        r.get "setting" do
          view "github/setting"
        end

        r.post true do
          unless r.params["cache_enabled"].nil?
            @installation.cache_enabled = r.params["cache_enabled"] == "true"
            flash["notice"] = "Transparent cache is #{@installation.cache_enabled ? "enabled" : "disabled"}"
          end

          unless r.params["performance_runner_enabled"].nil?
            @installation.allocator_preferences["family_filter"] = if r.params["performance_runner_enabled"] == "true"
              ["performance", "standard"]
            end
            @installation.modified!(:allocator_preferences)
            flash["notice"] = "High performance runners are #{@installation.performance_runner_enabled ? "enabled" : "disabled"}"
          end
          @installation.save_changes

          r.redirect "#{@project.path}/github/#{@installation.ubid}/setting"
        end

        r.on "runner" do
          r.get true do
            @runners = Serializers::GithubRunner.serialize(@installation.runners_dataset.eager(:vm, :strand).reverse(:created_at).all)

            view "github/runner"
          end

          r.is String do |runner_ubid|
            next unless (runner = GithubRunner.from_ubid(runner_ubid)) && runner.installation_id == @installation.id

            r.delete true do
              runner.incr_skip_deregistration
              runner.incr_destroy
              flash["notice"] = "Runner '#{runner.ubid}' forcibly terminated"
              204
            end
          end
        end

        r.on "cache" do
          r.get true do
            entries = @installation.cache_entries_dataset.exclude(committed_at: nil).eager(:repository).reverse(:created_at).all
            @entries_by_repo = Serializers::GithubCacheEntry.serialize(entries).group_by { it[:repository][:id] }
            @quota_per_repo = "#{@project.effective_quota_value("GithubRunnerCacheStorage")} GB"

            view "github/cache"
          end

          r.is String do |entry_ubid|
            next unless (entry = GithubCacheEntry.from_ubid(entry_ubid)) && entry.repository.installation_id == @installation.id

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
end
