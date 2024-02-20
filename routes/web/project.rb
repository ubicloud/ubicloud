# frozen_string_literal: true

class CloverWeb
  hash_branch("project") do |r|
    @serializer = Serializers::Web::Project

    r.get true do
      @projects = serialize(@current_user.projects.filter(&:visible))

      view "project/index"
    end

    r.post true do
      project = @current_user.create_project_with_default_policy(r.params["name"], provider: r.params["provider"])

      r.redirect project.path
    end

    r.is "create" do
      r.get true do
        view "project/create"
      end
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

      @project_data = serialize(@project)
      @project_permissions = Authorization.all_permissions(@current_user.id, @project.id)

      r.get true do
        Authorization.authorize(@current_user.id, "Project:view", @project.id)

        view "project/show"
      end

      r.post true do
        Authorization.authorize(@current_user.id, "Project:edit", @project.id)
        @project.update(name: r.params["name"])

        flash["notice"] = "The project name is updated to '#{@project.name}'."

        r.redirect @project.path
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Project:delete", @project.id)

        # If it has some resources, do not allow to delete it.
        if @project.has_resources
          flash["error"] = "'#{@project.name}' project has some resources. Delete all related resources first."
          return {message: "'#{@project.name}' project has some resources. Delete all related resources first."}.to_json
        end

        @project.soft_delete

        flash["notice"] = "'#{@project.name}' project is deleted."
        return {message: "'#{@project.name}' project is deleted."}.to_json
      end

      r.get "dashboard" do
        view "project/dashboard"
      end

      r.hash_branches(:project_prefix)
    end
  end
end
