# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get true do
      if api?
        result = Project.authorized(current_account.id, "Project:view").where(visible: true).paginated_result(
          start_after: r.params["start_after"],
          page_size: r.params["page_size"],
          order_column: r.params["order_column"]
        )

        {
          items: Serializers::Project.serialize(result[:records]),
          count: result[:count]
        }
      else
        @projects = Serializers::Project.serialize(current_account.projects.filter(&:visible), {include_path: true})
        view "project/index"
      end
    end

    r.post true do
      required_parameters = ["name"]
      request_body_params = Validation.validate_request_body(json_params, required_parameters)
      project = current_account.create_project_with_default_policy(request_body_params["name"])

      if api?
        Serializers::Project.serialize(project)
      else
        r.redirect project.path
      end
    end

    r.get(web?, "create") { view "project/create" }

    r.on String do |project_ubid|
      @project = Project.from_ubid(project_ubid)
      @project = nil unless @project&.visible

      unless @project
        response.status = r.delete? ? 204 : 404
        r.halt
      end

      unless @project.accounts.any? { _1.id == current_account.id }
        fail Authorization::Unauthorized
      end

      @project_data = Serializers::Project.serialize(@project, {include_path: true})
      @project_permissions = Authorization.all_permissions(current_account.id, @project.id)
      @quotas = ["VmCores", "PostgresCores"].map {
        {
          resource_type: _1,
          current_resource_usage: @project.current_resource_usage(_1),
          quota: @project.effective_quota_value(_1) * 2
        }
      }

      r.get true do
        Authorization.authorize(current_account.id, "Project:view", @project.id)

        if api?
          Serializers::Project.serialize(@project)
        else
          view "project/show"
        end
      end

      r.delete true do
        Authorization.authorize(current_account.id, "Project:delete", @project.id)

        if @project.has_resources
          fail DependencyError.new("'#{@project.name}' project has some resources. Delete all related resources first.")
        end

        @project.soft_delete

        if api?
          response.status = 204
          r.halt
        else
          flash["notice"] = "'#{@project.name}' project is deleted."
          return {message: "'#{@project.name}' project is deleted."}
        end
      end

      r.on web? do
        r.get("dashboard") { view("project/dashboard") }

        r.post true do
          Authorization.authorize(current_account.id, "Project:edit", @project.id)
          @project.update(name: r.params["name"])

          flash["notice"] = "The project name is updated to '#{@project.name}'."

          r.redirect @project.path
        end

        r.hash_branches(:project_prefix)
      end

      r.hash_branches(:api_project_prefix)
    end
  end

  hash_branch("project", &branch)
  hash_branch("api", "project", &branch)
end
