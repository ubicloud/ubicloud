# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "user") do |r|
    r.on web? do
      authorize("Project:user", @project.id)

      r.get true do
        @user_policies = {}
        @token_policies = {}
        @tokens = current_account.api_keys
        @project.access_policies_dataset.where(managed: true).each do |policy|
          policy.body["acls"].first["subjects"].each do |subject|
            # We plan to convert tags to UBIDs in our access policies while
            # persisting them. Until this change is implemented, we must locate
            # the access tag by its name. I opted for Ruby's 'find' method over
            # 'dataset' to repeatedly use cached data.
            if (account = Account[@project.access_tags.find { _1.name == subject }&.hyper_tag_id])
              @user_policies[account.ubid] = policy.name
            end
            if (token = @tokens.find { _1.hyper_tag_name == subject })
              @token_policies[token.ubid] = policy.name
            end
          end
        end
        @users = Serializers::Account.serialize(@project.accounts_dataset.order_by(:email).all)
        @invitations = Serializers::ProjectInvitation.serialize(@project.invitations_dataset.order_by(:email).all)
        @policy = Serializers::AccessPolicy.serialize(@project.access_policies_dataset.where(managed: false).first) || {body: {acls: []}.to_json}

        view "project/user"
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
          if (managed_policy = Authorization::ManagedPolicy.from_name(policy))
            managed_policy.apply(@project, [user], append: true)
          end
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
          r.redirect "#{@project.path}/user"
        end

        r.post "update-policies" do
          token_policies = r.params["token_policies"] || {}
          existing_tokens = current_account.api_keys.map(&:hyper_tag_name)
          [Authorization::ManagedPolicy::Admin, Authorization::ManagedPolicy::Member].each do |policy|
            tokens = token_policies.select { _2 == policy.name }.keys.map { ApiKey[owner_id: current_account_id, id: UBID.to_uuid(_1)] }
            # Do not modify existing user subjects or api_key subjects for other accounts
            policy.apply(@project, tokens, remove_subjects: existing_tokens) unless tokens.empty?
          end

          flash["notice"] = "Personal access token policies updated successfully."

          r.redirect "#{@project.path}/user"
        end

        r.delete String do |ubid|
          current_account.api_keys_dataset.with_pk(UBID.to_uuid(ubid))&.destroy
          response.status = 204
          nil
        end
      end

      r.on "policy" do
        r.post "managed" do
          user_policies = r.params["user_policies"] || {}
          # We iterate over all managed policies, not user_policies, to make sure
          # we clear out any policy that no one is using.
          [Authorization::ManagedPolicy::Admin, Authorization::ManagedPolicy::Member].each do |policy|
            accounts = user_policies.select { _2 == policy.name }.keys.map { Account.from_ubid(_1) }
            if policy == Authorization::ManagedPolicy::Admin && accounts.empty?
              flash["error"] = "The project must have at least one admin."
              redirect_back_with_inputs
            end
            # Do not modify existing api_token subjects
            policy.apply(@project, accounts, remove_subjects: "user/")
          end
          invitation_policies = r.params["invitation_policies"] || {}
          invitation_policies.each do |email, policy|
            @project.invitations.find { _1.email == email }&.update(policy: policy)
          end

          flash["notice"] = "User policies updated successfully."

          r.redirect "#{@project.path}/user"
        end

        r.post "advanced" do
          body = r.params["body"]
          begin
            fail JSON::ParserError unless JSON.parse(body).is_a?(Hash)
          rescue JSON::ParserError
            flash["error"] = "The policy isn't a valid JSON object."
            redirect_back_with_inputs
          end

          if (policy = @project.access_policies_dataset.where(managed: false).first)
            policy.update(body: body)
          else
            AccessPolicy.create_with_id(project_id: @project.id, name: "advanced", managed: false, body: body)
          end

          flash["notice"] = "Advanced policy updated for '#{@project.name}'"
          r.redirect "#{@project.path}/user"
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

        hyper_tag = user.hyper_tag_name(@project)
        @project.access_policies_dataset.where(managed: true).each do |policy|
          if policy.body["acls"].first["subjects"].include?(hyper_tag)
            policy.body["acls"].first["subjects"].delete(hyper_tag)
            policy.modified!(:body)
            policy.save_changes
          end
        end
        user.dissociate_with_project(@project)

        # Javascript refreshes page
        flash["notice"] = "Removed #{user.email} from #{@project.name}"
        204
      end
    end
  end
end
