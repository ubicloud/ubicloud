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
        if @project.github_installations.empty?
          r.redirect "#{@project.path}/github/setting"
        end
        r.redirect "#{@project.path}/github/runner"
      end

      r.on "runner" do
        r.get true do
          @runners = Serializers::GithubRunner.serialize(@project.github_runners_dataset.eager(:vm, :strand).reverse(:created_at).all)

          view "github/runner"
        end

        r.is String do |runner_ubid|
          next unless (runner = GithubRunner[id: UBID.to_uuid(runner_ubid), installation_id: GithubInstallation.select(:id).where(project_id: @project.id)])

          r.delete true do
            DB.transaction do
              runner.incr_skip_deregistration
              runner.incr_destroy
              audit_log(runner, "destroy")
            end
            flash["notice"] = "Runner '#{runner.ubid}' forcibly terminated"
            204
          end
        end
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
          next unless (installation = GithubInstallation[id: UBID.to_uuid(installation_id), project_id: @project.id])

          r.post true do
            cache_enabled = r.params["cache_enabled"] == "true"
            DB.transaction do
              installation.update(cache_enabled: cache_enabled)
              audit_log(installation, "update")
            end
            flash["notice"] = "Ubicloud cache is #{cache_enabled ? "enabled" : "disabled"} for the installation #{installation.name}."

            r.redirect "#{@project.path}/github/setting"
          end
        end
      end

      r.on "cache" do
        r.get true do
          repository_id_q = @project.github_installations_dataset.join(:github_repository, installation_id: :id).select(Sequel[:github_repository][:id])
          entries = GithubCacheEntry.where(repository_id: repository_id_q).exclude(committed_at: nil).eager(:repository).reverse(:created_at).all
          @entries_by_repo = Serializers::GithubCacheEntry.serialize(entries).group_by { it[:repository][:id] }
          @quota_per_repo = "#{@project.effective_quota_value("GithubRunnerCacheStorage")} GB"

          view "github/cache"
        end

        r.is String do |entry_ubid|
          next unless (entry = GithubCacheEntry.from_ubid(entry_ubid)) && entry.repository.installation.project_id == @project.id

          r.delete true do
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
