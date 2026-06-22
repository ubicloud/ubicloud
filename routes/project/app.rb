# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "app") do |r|
    r.is do
      r.get true do
        dataset = dataset_authorize(@project.app_resources_dataset, "AppResource:view")
        if api?
          {items: Serializers::AppResource.serialize(dataset.all)}
        else
          @app_resources = dataset.all
          view "app/index"
        end
      end

      r.post true do
        authorize("AppResource:create", @project)
        handle_validation_failure("app/create")
        name = typecast_params.nonempty_str!("name")
        repo_url = typecast_params.nonempty_str!("repo_url")
        branch = typecast_params.nonempty_str("branch") || "main"

        app_resource = nil
        DB.transaction do
          # v1 is single-region (eu-central). All backing resources are created
          # in the app service project by the nexus.
          app_resource = Prog::AppService::AppResourceNexus.assemble(
            project_id: @project.id,
            location_id: Location::HETZNER_FSN1_ID,
            name:,
            repo_url:,
            branch:,
          ).subject
          audit_log(app_resource, "create")
        end

        if api?
          Serializers::AppResource.serialize(app_resource)
        else
          flash["notice"] = "App '#{name}' created"
          r.redirect "#{@project.path}#{app_resource.path}"
        end
      end
    end

    r.get web?, "create" do
      authorize("AppResource:create", @project)
      view "app/create"
    end

    r.on APP_RESOURCE_NAME_OR_UBID do |name, id|
      app_resource = if name
        @project.app_resources_dataset.first(name:)
      else
        @project.app_resources_dataset.with_pk(id)
      end
      @app_resource = app_resource
      check_found_object(app_resource)

      r.get true do
        authorize("AppResource:view", app_resource)
        if api?
          Serializers::AppResource.serialize(app_resource, detailed: true)
        else
          r.redirect "#{@project.path}#{app_resource.path}/overview"
        end
      end

      # Metrics data for the app's attached database (CPU, memory, connections,
      # ...), pulled from VictoriaMetrics -- the same series the Postgres page
      # shows. JSON only (the chart JS fetches this with Accept: application/json,
      # and the API uses it too); the HTML page itself is the "metrics" tab below.
      # VM-level app metrics can be layered in here later.
      r.get "metrics", r.accepts_json? do
        authorize("AppResource:view", app_resource)
        pg = app_resource.postgres_resource
        raise CloverError.new(404, "NotFound", "No database attached") unless pg
        serve_postgres_metrics(pg.ubid)
      end

      # Left-menu subpages that render purely from the app resource. Each sets
      # @page and renders the shared app/show layout (left nav + right content).
      r.show_object(app_resource, actions: %w[overview deployments processes metrics settings], perm: "AppResource:view", template: "app/show")

      r.get "logs" do
        authorize("AppResource:view", app_resource)
        source = typecast_params.nonempty_str("source")
        logs = app_resource.logs(source:)
        if api?
          {logs:}
        else
          @page = "logs"
          @logs = logs
          @source = source
          view "app/show"
        end
      end

      # Config/secrets: a thin pass-through to the app's SecretStore (which lives
      # in the app service project, so it isn't reachable via the normal secret
      # store UI). The app VM reads it at build/run time via its managed identity.
      r.on "config" do
        r.is do
          r.get true do
            authorize("AppResource:view", app_resource)
            if api?
              {items: Serializers::Secret.serialize(app_resource.secret_store.secrets)}
            else
              @page = "config"
              view "app/show"
            end
          end

          r.post true do
            authorize("AppResource:edit", app_resource)
            handle_validation_failure("app/show") { @page = "config" }
            key = typecast_params.nonempty_str!("key")
            value = typecast_params.nonempty_str!("value")
            original_key = typecast_params.nonempty_str("original_key")

            secret_store = app_resource.secret_store
            secret = nil
            redeployed = nil
            DB.transaction do
              # Editing a row can rename its key; drop the old entry so the rename
              # doesn't leave a stale duplicate behind.
              if original_key && original_key != key
                secret_store.secrets_dataset.first(key: original_key)&.destroy
              end
              if (secret = secret_store.secrets_dataset.first(key:))
                secret.update(value:, updated_at: Time.now)
              else
                secret = secret_store.add_secret(key:, value:)
              end
              audit_log(app_resource, "update")
              redeployed = app_resource.redeploy_for_config_change
            end

            if api?
              Serializers::Secret.serialize(secret, detailed: true)
            else
              flash["notice"] = redeployed ? "Config '#{key}' saved; redeploying to apply it" : "Config '#{key}' saved"
              r.redirect "#{@project.path}#{app_resource.path}/config"
            end
          end
        end

        r.on(String) do |key|
          secret = app_resource.secret_store.secrets_dataset.first(key:)

          r.get api? do
            authorize("AppResource:view", app_resource)
            check_found_object(secret)
            Serializers::Secret.serialize(secret, detailed: true)
          end

          r.delete true do
            authorize("AppResource:edit", app_resource)
            check_found_object(secret)
            redeployed = nil
            DB.transaction do
              secret.destroy
              audit_log(app_resource, "update")
              redeployed = app_resource.redeploy_for_config_change
            end

            if api?
              204
            else
              flash["notice"] = redeployed ? "Config '#{key}' deleted; redeploying to apply it" : "Config '#{key}' deleted"
              r.redirect "#{@project.path}#{app_resource.path}/config"
            end
          end
        end
      end

      # Attached managed Postgres: provisioned in the app service project, the app
      # authenticates via its VM managed identity (cert), so nothing is stored.
      r.on "database" do
        r.get true do
          authorize("AppResource:view", app_resource)
          if api?
            {database: app_resource.database_connection}
          else
            @page = "database"
            view "app/show"
          end
        end

        r.post true do
          authorize("AppResource:edit", app_resource)
          raise CloverError.new(400, "InvalidRequest", "A database is already attached") if app_resource.postgres_resource

          DB.transaction do
            app_resource.attach_database
            audit_log(app_resource, "update")
          end

          if api?
            {database: app_resource.database_connection}
          else
            flash["notice"] = "Database is being provisioned"
            r.redirect "#{@project.path}#{app_resource.path}/database"
          end
        end

        r.delete true do
          authorize("AppResource:edit", app_resource)
          DB.transaction do
            app_resource.detach_database
            audit_log(app_resource, "update")
          end

          if api?
            204
          else
            flash["notice"] = "Database detached"
            r.redirect "#{@project.path}#{app_resource.path}/database"
          end
        end
      end

      r.post true do
        authorize("AppResource:edit", app_resource)
        handle_validation_failure("app/show") { @page = "settings" }
        repo_url = typecast_params.nonempty_str("repo_url")
        branch = typecast_params.nonempty_str("branch")

        DB.transaction do
          app_resource.repo_url = repo_url if repo_url
          app_resource.branch = branch if branch
          app_resource.save_changes
          audit_log(app_resource, "update")
        end

        if api?
          Serializers::AppResource.serialize(app_resource)
        else
          flash["notice"] = "App updated"
          r.redirect "#{@project.path}#{app_resource.path}/settings"
        end
      end

      r.post "deploy" do
        authorize("AppResource:edit", app_resource)
        deployment = app_resource.deploy
        audit_log(app_resource, "deploy")

        if api?
          Serializers::AppDeployment.serialize(deployment)
        else
          flash["notice"] = "Deploy of '#{app_resource.name}' started"
          r.redirect "#{@project.path}#{app_resource.path}/deployments"
        end
      end

      r.post "scale" do
        authorize("AppResource:edit", app_resource)
        handle_validation_failure("app/show") { @page = "processes" }
        process_type = typecast_params.nonempty_str!("process_type")
        replica_count = typecast_params.pos_int!("replica_count")
        vm_size = typecast_params.nonempty_str("vm_size")
        app_resource.scale(process_type, replica_count:, vm_size:)
        audit_log(app_resource, "update")

        if api?
          Serializers::AppResource.serialize(app_resource, detailed: true)
        else
          flash["notice"] = "Scaled #{process_type} to #{replica_count}"
          r.redirect "#{@project.path}#{app_resource.path}/processes"
        end
      end

      r.delete true do
        authorize("AppResource:delete", app_resource)
        DB.transaction do
          app_resource.incr_destroy
          audit_log(app_resource, "destroy")
        end

        if api?
          204
        else
          flash["notice"] = "App '#{app_resource.name}' is being deleted"
          r.redirect "#{@project.path}/app"
        end
      end
    end
  end
end
