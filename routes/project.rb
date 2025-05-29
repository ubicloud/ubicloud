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
          @projects = Serializers::Project.serialize(dataset.all, {include_path: true, web: true})
          view "project/index"
        end
      end

      r.post do
        no_authorization_needed
        if current_account.projects_dataset.count >= 10
          err_msg = "Project limit exceeded. You can create up to 10 projects. Contact support@ubicloud.com if you need more."
          if api?
            fail CloverError.new(400, "InvalidRequest", err_msg)
          else
            flash["error"] = err_msg
            r.redirect "/project"
          end
        end

        DB.transaction do
          @project = current_account.create_project_with_default_policy(typecast_params.nonempty_str!("name"))
          audit_log(@project, "create")
        end

        if api?
          Serializers::Project.serialize(@project)
        else
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

      @project_data = Serializers::Project.serialize(@project, {include_path: true, web: true})
      @project_permissions = all_permissions(@project.id) if web?

      r.get true do
        authorize("Project:view", @project.id)

        if api?
          Serializers::Project.serialize(@project)
        else
          @quotas = ["VmVCpu", "PostgresVCpu"].map {
            {
              resource_type: it,
              current_resource_usage: @project.current_resource_usage(it),
              quota: @project.effective_quota_value(it)
            }
          }

          view "project/show"
        end
      end

      r.delete true do
        authorize("Project:delete", @project.id)

        if @project.has_resources
          fail DependencyError.new("'#{@project.name}' project has some resources. Delete all related resources first.")
        end

        DB.transaction do
          @project.soft_delete
          audit_log(@project, "destroy")
        end

        204
      end

      if web?
        r.get("dashboard") do
          no_authorization_needed
          view("project/dashboard")
        end

        r.post true do
          authorize("Project:edit", @project.id)
          @project.update(name: typecast_params.nonempty_str!("name"))
          audit_log(@project, "update")

          flash["notice"] = "The project name is updated to '#{@project.name}'."

          r.redirect @project.path
        end
      end

      r.hash_branches(:project_prefix)
    end
  end
end
