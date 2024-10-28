# frozen_string_literal: true

class CloverApi
  hash_branch("project") do |r|
    r.get true do
      result = Project.authorized(current_account.id, "Project:view").where(visible: true).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: Serializers::Project.serialize(result[:records]),
        count: result[:count]
      }
    end

    r.post true do
      required_parameters = ["name"]

      request_body_params = Validation.validate_request_body(r.body.read, required_parameters)

      project = current_account.create_project_with_default_policy(request_body_params["name"])

      Serializers::Project.serialize(project)
    end

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

      r.delete true do
        Authorization.authorize(current_account.id, "Project:delete", @project.id)

        # If it has some resources, do not allow to delete it.
        if @project.has_resources
          fail DependencyError.new("'#{@project.name}' project has some resources. Delete all related resources first.")
        end

        @project.soft_delete

        response.status = 204
        r.halt
      end

      r.get true do
        Authorization.authorize(current_account.id, "Project:view", @project.id)

        Serializers::Project.serialize(@project)
      end

      r.hash_branches(:project_prefix)
    end
  end
end
