# frozen_string_literal: true

class Clover
  hash_branch("project") do |r|
    r.get true do
      no_authorization_needed
      dataset = current_account.projects_dataset.where(visible: true)

      if api?
        result = dataset.paginated_result(
          start_after: r.params["start_after"],
          page_size: r.params["page_size"],
          order_column: r.params["order_column"]
        )

        {
          items: Serializers::Project.serialize(result[:records]),
          count: result[:count]
        }
      else
        @projects = Serializers::Project.serialize(dataset.all, {include_path: true, web: true})
        view "project/index"
      end
    end

    r.post true do
      required_parameters = ["name"]
      request_body_params = validate_request_params(required_parameters)
      project = current_account.create_project_with_default_policy(request_body_params["name"])
      no_authorization_needed

      if api?
        Serializers::Project.serialize(project)
      else
        r.redirect project.path
      end
    end

    r.get(web?, "create") do
      no_authorization_needed
      view "project/create"
    end

    r.on String do |project_ubid|
      @project = Project.from_ubid(project_ubid)
      @project = nil unless @project&.visible

      check_found_object(@project)

      if @project.accounts_dataset.where(Sequel[:accounts][:id] => current_account_id).empty?
        fail Authorization::Unauthorized
      end

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

        @project.soft_delete

        204
      end

      if web?
        r.get("dashboard") do
          no_authorization_needed
          view("project/dashboard")
        end

        r.post true do
          authorize("Project:edit", @project.id)
          @project.update(name: r.params["name"])

          flash["notice"] = "The project name is updated to '#{@project.name}'."

          r.redirect @project.path
        end
      end

      r.hash_branches(:project_prefix)
    end
  end
end
