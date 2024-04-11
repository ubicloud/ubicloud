# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "user") do |r|
    Authorization.authorize(@current_user.id, "Project:user", @project.id)
    @serializer = Serializers::Web::Account

    r.get true do
      users_with_hyper_tag = @project.user_ids
      @users = serialize(Account.where(id: users_with_hyper_tag).all)

      view "project/user"
    end

    r.post true do
      email = r.params["email"]
      user = Account[email: email]

      user&.associate_with_project(@project)

      Util.send_email(email, "Invitation to Join '#{@project.name}' Project on Ubicloud",
        greeting: "Hello,",
        body: ["You're invited by '#{@current_user.name}' to join the '#{@project.name}' project on Ubicloud.",
          "To join project, click the button below.",
          "For any questions or assistance, reach out to our team at support@ubicloud.com."],
        button_title: "Join Project",
        button_link: "#{Config.base_url}#{@project.path}/dashboard")

      flash["notice"] = "Invitation sent successfully to '#{email}'. You need to add some policies to allow new user to operate in the project.
                        If this user doesn't have account, they will need to create an account and you'll need to add them again."

      r.redirect "#{@project.path}/user"
    end

    r.is String do |user_ubid|
      user = Account.from_ubid(user_ubid)

      unless user
        response.status = 404
        r.halt
      end

      r.delete true do
        unless @project.user_ids.count > 1
          response.status = 400
          return {message: "You can't remove the last user from '#{@project.name}' project. Delete project instead."}.to_json
        end

        user.dissociate_with_project(@project)

        return {message: "Removing #{user.email} from #{@project.name}"}.to_json
      end
    end
  end
end
