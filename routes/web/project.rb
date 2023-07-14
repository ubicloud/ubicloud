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
      project = Project.from_ulid(project_ulid)

      unless project
        response.status = 404
        r.halt
      end

      @project_data = serialize(project)

      r.get true do
        Authorization.authorize(@current_user.id, "Project:view", project.id)

        view "project/show_details"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Project:delete", project.id)

        # If it has some resources, do not allow to delete it.
        if project.access_tags_dataset.exclude(hyper_tag_table: [Account.table_name.to_s, Project.table_name.to_s, AccessTag.table_name.to_s]).count > 0
          flash["error"] = "'#{project.name}' project has some resources. Delete all related resources first."
          return {message: "'#{project.name}' project has some resources. Delete all related resources first."}.to_json
        end

        DB.transaction do
          project.access_tags.each { |access_tag| access_tag.applied_tags_dataset.delete }
          project.access_tags_dataset.delete
          project.access_policies_dataset.delete
          project.delete
        end

        flash["notice"] = "'#{project.name}' project is deleted."
        return {message: "'#{project.name}' project is deleted."}.to_json
      end

      r.on "user" do
        Authorization.authorize(@current_user.id, "Project:user", project.id)
        @serializer = Serializers::Web::Account

        r.get true do
          users_with_hyper_tag = project.user_ids
          @users = serialize(Account.where(id: users_with_hyper_tag).all)

          view "project/show_users"
        end

        r.post true do
          email = r.params["email"]
          user = Account[email: email]

          user&.associate_with_project(project)

          # TODO(enes): Move notifications to separate classes
          send_email(email, "Invitation to Join '#{project.name}' Project on Ubicloud",
            greeting: "Hello,",
            body: ["You're invited by '#{@current_user.name}' to join the '#{project.name}' project on Ubicloud.",
              "To join project, click the button below.",
              "For any questions or assistance, reach out to our team at support@ubicloud.com."],
            button_title: "Join Project",
            button_link: base_url + project.path)

          flash["notice"] = "Invitation sent successfully to '#{email}'. You need to add some policies to allow new user to operate in the project.
                            If this user doesn't have account, they will need to create an account and you'll need to add them again."

          r.redirect "#{project.path}/user"
        end

        r.is String do |user_ulid|
          user = Account.from_ulid(user_ulid)

          unless user
            response.status = 404
            r.halt
          end

          r.delete true do
            unless project.user_ids.count > 1
              response.status = 400
              return {message: "You can't remove the last user from '#{project.name}' project. Delete project instead."}.to_json
            end

            user.dissociate_with_project(project)

            return {message: "Removing #{user.email} from #{project.name}"}.to_json
          end
        end
      end

      r.on "policy" do
        Authorization.authorize(@current_user.id, "Project:policy", project.id)
        @serializer = Serializers::Web::AccessPolicy

        r.get true do
          # For UI simplicity, we are showing only one policy at the moment
          @policy = serialize(project.access_policies.first)

          view "project/show_policies"
        end

        r.is String do |policy_ulid|
          policy = AccessPolicy.from_ulid(policy_ulid)

          unless policy
            response.status = 404
            r.halt
          end

          r.post true do
            body = r.params["body"]

            begin
              fail JSON::ParserError unless JSON.parse(body).is_a?(Hash)
            rescue JSON::ParserError
              flash["error"] = "The policy isn't a valid JSON object."
              return redirect_back_with_inputs
            end

            policy.update(body: body)

            flash["notice"] = "'#{policy.name}' policy updated for '#{project.name}'"

            r.redirect "#{project.path}/policy"
          end
        end
      end
    end
  end
end
