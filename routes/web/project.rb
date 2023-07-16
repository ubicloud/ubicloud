# frozen_string_literal: true

require "ulid"

class CloverWeb
  hash_branch("project") do |r|
    @serializer = Serializers::Web::Project

    r.get true do
      @projects = serialize(@current_user.projects)

      view "project/index"
    end

    r.post true do
      project = @current_user.create_project_with_default_policy(r.params["name"])

      r.redirect project.path
    end

    r.is "create" do
      r.get true do
        view "project/create"
      end
    end

    r.on String do |project_ulid|
      @project = Project.from_ulid(project_ulid)

      unless @project
        response.status = 404
        r.halt
      end

      @project_data = serialize(@project)

      r.get true do
        Authorization.authorize(@current_user.id, "Project:view", @project.id)

        view "project/show_details"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Project:delete", @project.id)

        # If it has some resources, do not allow to delete it.
        if @project.access_tags_dataset.exclude(hyper_tag_table: [Account.table_name.to_s, Project.table_name.to_s, AccessTag.table_name.to_s]).count > 0
          flash["error"] = "'#{@project.name}' project has some resources. Delete all related resources first."
          return {message: "'#{@project.name}' project has some resources. Delete all related resources first."}.to_json
        end

        DB.transaction do
          @project.access_tags.each { |access_tag| access_tag.applied_tags_dataset.delete }
          @project.access_tags_dataset.delete
          @project.access_policies_dataset.delete
          @project.delete
        end

        flash["notice"] = "'#{@project.name}' project is deleted."
        return {message: "'#{@project.name}' project is deleted."}.to_json
      end

      r.get "dashboard" do
        Authorization.authorize(@current_user.id, "Project:view", @project.id)

        view "project/dashboard"
      end

      r.hash_branches(:project_prefix)
    end
  end
end
