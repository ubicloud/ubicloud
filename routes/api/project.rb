# frozen_string_literal: true

class CloverApi
  hash_branch("project") do |r|
    @serializer = Serializers::Api::Project

    r.get true do
      projects = Project.authorized(@current_user.id, "Project:view").all

      serialize(projects)
    end

    r.post true do
      project = @current_user.create_project_with_default_policy(r.params["name"], provider: r.params["provider"])

      serialize(project)
    end

    r.on String do |project_ubid|
      @project = Project.from_ubid(project_ubid)

      unless @project
        response.status = 404
        r.halt
      end

      r.get true do
        Authorization.authorize(@current_user.id, "Project:view", @project.id)

        serialize(@project)
      end

      r.hash_branches(:project_prefix)
    end
  end
end
