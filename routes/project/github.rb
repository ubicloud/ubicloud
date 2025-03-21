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
        if (installation = @project.github_installations_dataset.first)
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

      r.on :ubid_uuid do |id|
        next unless (@installation = GithubInstallation[id:, project_id: @project.id])

        r.get "setting" do
          view "github/setting"
        end

        r.post true do
          unless r.params["cache_enabled"].nil?
            @installation.cache_enabled = r.params["cache_enabled"] == "true"
            flash["notice"] = "Transparent cache is #{@installation.cache_enabled ? "enabled" : "disabled"}"
          end

          unless r.params["premium_runner_enabled"].nil?
            @installation.allocator_preferences["family_filter"] = if r.params["premium_runner_enabled"] == "true"
              ["premium", "standard"]
            end
            @installation.modified!(:allocator_preferences)
            flash["notice"] = "Premium runners are #{@installation.premium_runner_enabled? ? "enabled" : "disabled"}"
          end
          DB.transaction do
            @installation.save_changes
            audit_log(@installation, "update")
          end

          r.redirect "#{@project.path}/github/#{@installation.ubid}/setting"
        end

        r.on "runner" do
          r.get true do
            @runners = @project.github_runners_dataset.eager(:vm, :strand).reverse(:created_at).all

            view "github/runner"
          end

          r.delete :ubid_uuid do |id|
            next unless (runner = GithubRunner[id:, installation_id: GithubInstallation.select(:id).where(project_id: @project.id)])

            DB.transaction do
              runner.incr_skip_deregistration
              runner.incr_destroy
              audit_log(runner, "destroy")
            end
            flash["notice"] = "Runner '#{runner.ubid}' forcibly terminated"
            204
          end
        end

        r.on "cache" do
          r.get true do
            entries = @installation.cache_entries_dataset.exclude(committed_at: nil).eager(:repository).reverse(:created_at).all
            @entries_by_repo = Serializers::GithubCacheEntry.serialize(entries).group_by { it[:repository][:id] }
            @quota_per_repo = "#{@project.effective_quota_value("GithubRunnerCacheStorage")} GB"

            view "github/cache"
          end

          r.delete :ubid_uuid do |id|
            next unless (entry = GithubCacheEntry[id:, repository_id: GithubRepository.select(:id).where(installation_id: GithubInstallation.select(:id).where(project_id: @project.id))])

            DB.transaction do
              entry.destroy
              audit_log(entry, "destroy")
            end
            flash["notice"] = "Cache '#{entry.key}' deleted."
            204
          end
        end
      end
    end
  end
end
