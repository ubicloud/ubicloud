# frozen_string_literal: true

class Clover
  hash_branch("project") do |r|
    r.is do
      r.get do
        no_authorization_needed
        dataset = current_account.projects_dataset.where(visible: true)

        if api?
          paginated_result(dataset, Serializers::Project)
        else
          @projects = dataset.all
          view "project/index"
        end
      end

      r.post do
        no_authorization_needed
        handle_validation_failure("project/create")

        if current_account.projects_dataset.count >= 10
          fail CloverError.new(400, "InvalidRequest", "Project limit exceeded. You can create up to 10 projects. Contact support@ubicloud.com if you need more.")
        end

        DB.transaction do
          @project = current_account.create_project_with_default_policy(typecast_params.nonempty_str!("name"))
          audit_log(@project, "create")
        end

        if api?
          Serializers::Project.serialize(@project)
        else
          flash["notice"] = "Project created"
          r.redirect @project.path
        end
      end
    end

    r.get(web?, "create") do
      no_authorization_needed
      view "project/create"
    end

    r.on :ubid_uuid do |project_id|
      @project = Clover.authorized_project(current_account, project_id)
      check_found_object(@project)

      @project_permissions = all_permissions(@project.id) if web?

      r.is do
        r.get do
          authorize("Project:view", @project.id)

          if api?
            Serializers::Project.serialize(@project)
          else
            view "project/show"
          end
        end

        r.delete do
          authorize("Project:delete", @project.id)

          if @project.has_resources?
            fail DependencyError.new("'#{@project.name}' project has some resources. Delete all related resources first.")
          end

          DB.transaction do
            @project.soft_delete
            audit_log(@project, "destroy")
          end

          204
        end

        r.post web? do
          authorize("Project:edit", @project.id)

          handle_validation_failure("project/show")

          DB.transaction do
            @project.update(name: typecast_params.nonempty_str!("name"))
            audit_log(@project, "update")
          end

          flash["notice"] = "The project name is updated to '#{@project.name}'."

          r.redirect @project.path
        end
      end

      r.get(web?, "dashboard") do
        no_authorization_needed
        view("project/dashboard")
      end

      r.hash_branches(:project_prefix)
    end
  end
end
