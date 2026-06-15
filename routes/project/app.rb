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
        target_vm_size = typecast_params.nonempty_str("target_vm_size") || "standard-2"

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
            target_vm_size:,
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
          view "app/show"
        end
      end

      r.post true do
        authorize("AppResource:edit", app_resource)
        handle_validation_failure("app/show")
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
          r.redirect "#{@project.path}#{app_resource.path}"
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
          r.redirect "#{@project.path}#{app_resource.path}"
        end
      end

      r.post "scale" do
        authorize("AppResource:edit", app_resource)
        handle_validation_failure("app/show")
        process_type = typecast_params.nonempty_str!("process_type")
        replica_count = typecast_params.pos_int!("replica_count")
        vm_size = typecast_params.nonempty_str("vm_size")
        app_resource.scale(process_type, replica_count:, vm_size:)
        audit_log(app_resource, "update")

        if api?
          Serializers::AppResource.serialize(app_resource, detailed: true)
        else
          flash["notice"] = "Scaled #{process_type} to #{replica_count}"
          r.redirect "#{@project.path}#{app_resource.path}"
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
