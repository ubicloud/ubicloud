# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "github") do |r|
    unless Config.github_app_name
      response.status = 501
      response.content_type = :text
      next "GitHub Action Runner integration is not enabled. Set GITHUB_APP_NAME to enable it."
    end

    authorize("Project:github", @project)

    r.get true do
      ds = @project.github_installations_dataset

      if api?
        paginated_result(ds, Serializers::GithubInstallation)
      else
        if (installation = ds.first)
          r.redirect installation, "/runner"
        end
        view "github/index"
      end
    end

    r.get web?, "create" do
      handle_validation_failure("github/index")
      unless @project.has_valid_payment_method?
        raise_web_error("Project doesn't have valid billing information")
      end
      session[:github_installation_project_id] = @project.id

      r.redirect "https://github.com/apps/#{Config.github_app_name}/installations/new", 302
    end

    r.on GITHUB_INSTALLATION_NAME_OR_UBID do |installation_name, installation_id|
      installation = if installation_name
        @project.github_installations_dataset.first(name: installation_name)
      else
        @project.github_installations_dataset.with_pk(installation_id)
      end
      check_found_object(installation)
      @installation = installation

      r.get api? do
        Serializers::GithubInstallation.serialize(installation)
      end

      r.get web?, "setting" do
        view "github/setting"
      end

      r.post web? do
        if typecast_params.present?("cache_enabled")
          @installation.cache_enabled = typecast_params.bool("cache_enabled")
        end

        if typecast_params.present?("premium_runner_enabled")
          @installation.allocator_preferences["family_filter"] = if typecast_params.bool("premium_runner_enabled")
            ["premium", "standard"]
          end
          @installation.modified!(:allocator_preferences)
        end
        DB.transaction do
          @installation.save_changes
          audit_log(@installation, "update")
        end

        r.redirect @installation, "/setting"
      end

      r.on web?, "runner" do
        r.get true do
          @runners = @installation.runners_dataset.eager(:vm).eager_graph(:strand)
            .exclude(Sequel[:strand][:prog] => "Vm::GithubRunner", Sequel[:strand][:label] => ["destroy", "wait_vm_destroy"])
            .reverse(Sequel[:github_runner][:created_at])
            .all

          view "github/runner"
        end

        r.delete :ubid_uuid do |id|
          next unless (runner = @installation.runners_dataset.with_pk(id))

          DB.transaction do
            runner.incr_skip_deregistration
            runner.incr_destroy
            audit_log(runner, "destroy")
          end
          flash["notice"] = "Runner '#{runner.ubid}' forcibly terminated"
          204
        end
      end

      r.get web?, "cache" do
        @entries_by_repo = @installation
          .cache_entries_dataset
          .exclude(committed_at: nil)
          .eager(:repository)
          .reverse(:created_at)
          .all
          .group_by { it.repository.ubid }

        @quota_per_repo = "#{@installation.cache_storage_gib} GB"
        view "github/cache"
      end

      r.on "repository" do
        r.get api? do
          paginated_result(installation.repositories_dataset.order(:name), Serializers::GithubRepository, installation:)
        end

        r.on GITHUB_REPOSITORY_NAME_OR_UBID do |repository_name, repository_id|
          repository = if repository_name
            installation.repositories_dataset.first(name: "#{installation.name}/#{repository_name}")
          else
            installation.repositories_dataset.with_pk(repository_id)
          end
          check_found_object(repository)

          r.get api? do
            Serializers::GithubRepository.serialize(repository, installation:)
          end

          r.on "cache" do
            r.get api? do
              paginated_result(repository.cache_entries_dataset.order(:id), Serializers::GithubCacheEntry, installation:, repository:)
            end

            r.delete true do
              if repository.cache_entries_dataset.empty?
                no_audit_log
                notice = "No existing cache entries to delete"
              else
                DB.transaction do
                  Prog::Github::DeleteCacheEntries.assemble(repository.id)
                  audit_log(repository, "delete_all_cache_entries")
                end
                notice = "Scheduled deletion of existing cache entries"
              end

              flash["notice"] = notice if web?
              204
            end

            r.is :ubid_uuid do |id|
              entry = repository.cache_entries_dataset.with_pk(id)
              check_found_object(entry)

              r.get api? do
                Serializers::GithubCacheEntry.serialize(entry, installation:, repository:)
              end

              r.delete do
                DB.transaction do
                  entry.destroy
                  audit_log(entry, "destroy")
                end
                flash["notice"] = "Cache '#{entry.key}' deleted." if web?
                204
              end
            end
          end
        end
      end
    end
  end
end
