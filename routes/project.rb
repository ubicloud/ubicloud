# frozen_string_literal: true

class Clover
  hash_branch("project") do |r|
    r.is do
      r.get do
        no_authorization_needed

        if api?
          paginated_result(current_account.projects_dataset.where(:visible), Serializers::Project)
        else
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
          r.redirect @project
        end
      end
    end

    r.post web?, "set-default", :ubid_uuid do |project_id|
      no_authorization_needed
      no_audit_log

      if (project = current_account.projects_dataset.with_pk(project_id))
        current_account.default_project = project
        flash["notice"] = "Default project updated"
      else
        flash["error"] = "Invalid default project selected"
      end

      r.redirect "/project"
    end

    r.on web?, "invitation", :ubid_uuid do |project_id|
      invitation = current_account.invitations_dataset.first(project_id:)
      check_found_object(invitation)
      no_authorization_needed
      handle_validation_failure("project/index")

      r.post "accept" do
        success = true

        DB.transaction do
          result = DB[:access_tag]
            .returning(:hyper_tag_id)
            .insert_conflict
            .insert(hyper_tag_id: current_account.id, project_id:)

          if result.empty?
            success = false
            no_audit_log
          else
            invitation
              .project
              .subject_tags_dataset
              .first(name: invitation.policy)
              &.add_subject(current_account.id)
            audit_log(current_account, "accept_invitation", project_id: invitation.project_id)
          end

          # Destroy invitation whether or not the account is already a project member
          invitation.destroy
        end

        raise_web_error("You are already a member of the project, ignoring invitation") unless success
        flash["notice"] = "Accepted invitation to join project"
        r.redirect "/project"
      end

      r.post "decline" do
        DB.transaction do
          invitation.destroy
          audit_log(current_account, "decline_invitation", project_id: invitation.project_id)
        end
        flash["notice"] = "Declined invitation to join project"
        r.redirect "/project"
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

      r.get true do
        authorize("Project:view", @project)

        if api?
          Serializers::Project.serialize(@project)
        else
          view "project/show"
        end
      end

      r.delete true do
        authorize("Project:delete", @project)
        handle_validation_failure("project/show")

        if @project.has_resources?
          fail DependencyError.new("'#{@project.name}' project has some resources. Delete all related resources first.")
        end

        DB.transaction do
          @project.soft_delete
          audit_log(@project, "destroy")
        end

        if web?
          flash["notice"] = "Project deleted"
          r.redirect "/project"
        else
          204
        end
      end

      r.post web? do
        authorize("Project:edit", @project)

        handle_validation_failure("project/show")

        DB.transaction do
          @project.update(name: typecast_params.nonempty_str!("name"))
          audit_log(@project, "update")
        end

        flash["notice"] = "The project name is updated to '#{@project.name}'."

        r.redirect @project
      end

      r.get(web?, "dashboard") do
        no_authorization_needed
        view("project/dashboard")
      end

      r.hash_branches(:project_prefix)
    end
  end
end
