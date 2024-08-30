# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "user") do |r|
    Authorization.authorize(@current_user.id, "Project:user", @project.id)

    r.get true do
      @users = Serializers::Account.serialize(@project.accounts)
      @invitations = Serializers::ProjectInvitation.serialize(@project.invitations)

      view "project/user"
    end

    r.post true do
      email = r.params["email"]

      if (user = Account.exclude(status_id: 3)[email: email])
        user.associate_with_project(@project)
      elsif ProjectInvitation[project_id: @project.id, email: email]
        flash["error"] = "'#{email}' already invited to join the project."
        r.redirect "#{@project.path}/user"
      elsif @project.invitations_dataset.count >= 50
        flash["error"] = "You can't have more than 50 pending invitations."
        r.redirect "#{@project.path}/user"
      else
        @project.add_invitation(email: email, inviter_id: @current_user.id, expires_at: Time.now + 7 * 24 * 60 * 60)
      end

      Util.send_email(email, "Invitation to Join '#{@project.name}' Project on Ubicloud",
        greeting: "Hello,",
        body: ["You're invited by '#{@current_user.name}' to join the '#{@project.name}' project on Ubicloud.",
          "To join project, click the button below.",
          "For any questions or assistance, reach out to our team at support@ubicloud.com."],
        button_title: "Join Project",
        button_link: "#{Config.base_url}#{@project.path}/dashboard")

      flash["notice"] = "Invitation sent successfully to '#{email}'. You need to add some policies to allow new user to operate in the project."

      r.redirect "#{@project.path}/user"
    end

    r.on "invitation" do
      r.is String do |email|
        r.delete true do
          @project.invitations_dataset.where(email: email).destroy
          flash["notice"] = "Invitation for '#{email}' is removed successfully."
          r.halt
        end
      end
    end

    r.is String do |user_ubid|
      user = Account.from_ubid(user_ubid)

      unless user
        response.status = 404
        r.halt
      end

      r.delete true do
        unless @project.accounts.count > 1
          response.status = 400
          return {message: "You can't remove the last user from '#{@project.name}' project. Delete project instead."}.to_json
        end

        user.dissociate_with_project(@project)

        return {message: "Removing #{user.email} from #{@project.name}"}.to_json
      end
    end
  end
end
