# frozen_string_literal: true

class CloverApi
  hash_branch("project") do |r|
    @serializer = Serializers::Api::Project

    r.get true do
      projects = Project.authorized(@current_user.id, "Project:view").all.filter(&:visible)

      serialize(projects)
    end

    r.post true do
      project = @current_user.create_project_with_default_policy(r.params["name"], provider: r.params["provider"])

      serialize(project)
    end

    r.on String do |project_ubid|
      @project = Project.from_ubid(project_ubid)
      @project = nil unless @project&.visible

      unless @project
        response.status = 404
        r.halt
      end

      unless @project.user_ids.include?(@current_user.id)
        fail Authorization::Unauthorized
      end

      r.get true do
        Authorization.authorize(@current_user.id, "Project:view", @project.id)

        serialize(@project)
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Project:delete", @project.id)

        # If it has some resources, do not allow to delete it.
        if @project.has_resources
          fail ErrorCodes::DependencyError.new("'#{@project.name}' project has some resources. Delete all related resources first.")
        end

        @project.soft_delete

        return {message: "'#{@project.name}' project is deleted."}.to_json
      end

      r.hash_branches(:project_prefix)
    end
  end
end
