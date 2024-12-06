# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "user") do |r|
    r.on web? do
      authorize("Project:user", @project.id)

      r.get true do
        @users = Serializers::Account.serialize(@project.accounts_dataset.order_by(:email).all)
        @invitations = Serializers::ProjectInvitation.serialize(@project.invitations_dataset.order_by(:email).all)
        view "project/user"
      end

      r.get "token" do
        @tokens = current_account.api_keys
        view "project/token"
      end

      r.post true do
        email = r.params["email"]
        policy = r.params["policy"]

        if ProjectInvitation[project_id: @project.id, email: email]
          flash["error"] = "'#{email}' already invited to join the project."
          r.redirect "#{@project.path}/user"
        elsif @project.invitations_dataset.count >= 50
          flash["error"] = "You can't have more than 50 pending invitations."
          r.redirect "#{@project.path}/user"
        end

        if (user = Account.exclude(status_id: 3)[email: email])
          user.associate_with_project(@project)
          @project.subject_tags_dataset.first(name: policy)&.add_subject(user.id)
          Util.send_email(email, "Invitation to Join '#{@project.name}' Project on Ubicloud",
            greeting: "Hello,",
            body: ["You're invited by '#{current_account.name}' to join the '#{@project.name}' project on Ubicloud.",
              "To join project, click the button below.",
              "For any questions or assistance, reach out to our team at support@ubicloud.com."],
            button_title: "Join Project",
            button_link: "#{Config.base_url}#{@project.path}/dashboard")
        else
          @project.add_invitation(email: email, policy: policy, inviter_id: current_account_id, expires_at: Time.now + 7 * 24 * 60 * 60)
          Util.send_email(email, "Invitation to Join '#{@project.name}' Project on Ubicloud",
            greeting: "Hello,",
            body: ["You're invited by '#{current_account.name}' to join the '#{@project.name}' project on Ubicloud.",
              "To join project, you need to create an account on Ubicloud. Once you create an account, you'll be automatically joined to the project.",
              "For any questions or assistance, reach out to our team at support@ubicloud.com."],
            button_title: "Create Account",
            button_link: "#{Config.base_url}/create-account")
        end

        flash["notice"] = "Invitation sent successfully to '#{email}'. You need to add some policies to allow new user to operate in the project."

        r.redirect "#{@project.path}/user"
      end

      r.on "token" do
        r.post true do
          pat = DB.transaction { ApiKey.create_personal_access_token(current_account, project: @project) }
          flash["notice"] = "Created personal access token with id #{pat.ubid}"
          r.redirect "#{@project.path}/user/token"
        end

        r.delete String do |ubid|
          if (token = current_account.api_keys_dataset.with_pk(UBID.to_uuid(ubid)))
            token.destroy
            @project.disassociate_subject(token.id)
            flash["notice"] = "Personal access token deleted successfully"
          end
          204
        end
      end

      r.on "policy" do
        r.post "managed" do
          invitation_policies = r.params["invitation_policies"] || {}
          invitation_policies.each do |email, policy|
            @project.invitations.find { _1.email == email }&.update(policy: policy)
          end

          flash["notice"] = "Subject tags for invited users updated successfully."

          r.redirect "#{@project.path}/user"
        end
      end

      r.on "access-control" do
        r.get true do
          uuids = {}
          @project.access_control_entries.each do |ace|
            # Omit personal action token subjects
            uuids[ace.subject_id] = nil unless UBID.uuid_class_match?(ace.subject_id, ApiKey)
            uuids[ace.action_id] = nil if ace.action_id
            uuids[ace.object_id] = nil if ace.object_id
          end
          UBID.resolve_map(uuids)
          @aces = @project.access_control_entries.map do |ace|
            next unless (subject = uuids[ace.subject_id])
            editable = !(subject.is_a?(SubjectTag) && subject.name == "Admin")
            [ace.ubid, [subject, uuids[ace.action_id], uuids[ace.object_id]], editable]
          end
          @aces.compact!
          sort_aces!(@aces)

          view "project/access-control"
        end

        r.is "entry", String do |ubid|
          if ubid == "new"
            @ace = AccessControlEntry.new_with_id(project_id: @project.id)
          else
            next unless (@ace = AccessControlEntry[project_id: @project.id, id: UBID.to_uuid(ubid)])
            check_ace_subject(@ace.subject_id)
          end

          r.get do
            view "project/access-control-entry"
          end

          r.post do
            was_new = @ace.new?

            subject, action, object = typecast_params.nonempty_str(%w[subject action object])
            check_ace_subject(UBID.to_uuid(subject))
            @ace.from_ubids(subject, action, object).save_changes

            flash["notice"] = "Access control entry #{was_new ? "created" : "updated"} successfully"
            r.redirect "#{@project_data[:path]}/user/access-control"
          end

          r.delete(!@ace.new?) do
            @ace.destroy
            flash["notice"] = "Access control entry deleted successfully"
            204
          end
        end
      end

      r.delete "invitation", String do |email|
        @project.invitations_dataset.where(email: email).destroy
        # Javascript handles redirect
        flash["notice"] = "Invitation for '#{email}' is removed successfully."
        204
      end

      r.delete String do |user_ubid|
        next unless (user = Account.from_ubid(user_ubid))

        unless @project.accounts.count > 1
          response.status = 400
          next {error: {message: "You can't remove the last user from '#{@project.name}' project. Delete project instead."}}
        end

        @project.disassociate_subject(user.id)
        user.dissociate_with_project(@project)

        # Javascript refreshes page
        flash["notice"] = "Removed #{user.email} from #{@project.name}"
        204
      end
    end
  end
end
