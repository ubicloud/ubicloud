# frozen_string_literal: true

class Clover
  tag_perm_map = {
    "subject" => "Project:subjtag",
    "action" => "Project:acttag",
    "object" => "Project:objtag"
  }.freeze

  hash_branch(:project_prefix, "user") do |r|
    r.web do
      r.is do
        authorize("Project:user", @project.id)

        r.get do
          @users = Serializers::Account.serialize(@project.accounts_dataset.order_by(:email).all)
          @invitations = Serializers::ProjectInvitation.serialize(@project.invitations_dataset.order_by(:email).all)
          view "project/user"
        end

        r.post do
          email = r.params["email"]
          policy = r.params["policy"]

          if ProjectInvitation[project_id: @project.id, email: email]
            flash["error"] = "'#{email}' already invited to join the project."
            r.redirect "#{@project.path}/user"
          elsif @project.invitations_dataset.count >= 50
            flash["error"] = "You can't have more than 50 pending invitations."
            r.redirect "#{@project.path}/user"
          end

          tag = dataset_authorize(@project.subject_tags_dataset, "SubjectTag:add").first(name: policy)
          if (user = Account.exclude(status_id: 3)[email: email])
            user.associate_with_project(@project)
            tag&.add_subject(user.id)
            Util.send_email(email, "Invitation to Join '#{@project.name}' Project on Ubicloud",
              greeting: "Hello,",
              body: ["You're invited by '#{current_account.name}' to join the '#{@project.name}' project on Ubicloud.",
                "To join project, click the button below.",
                "For any questions or assistance, reach out to our team at support@ubicloud.com."],
              button_title: "Join Project",
              button_link: "#{Config.base_url}#{@project.path}/dashboard")
          else
            @project.add_invitation(email: email, policy: (policy if tag), inviter_id: current_account_id, expires_at: Time.now + 7 * 24 * 60 * 60)
            Util.send_email(email, "Invitation to Join '#{@project.name}' Project on Ubicloud",
              greeting: "Hello,",
              body: ["You're invited by '#{current_account.name}' to join the '#{@project.name}' project on Ubicloud.",
                "To join project, you need to create an account on Ubicloud. Once you create an account, you'll be automatically joined to the project.",
                "For any questions or assistance, reach out to our team at support@ubicloud.com."],
              button_title: "Create Account",
              button_link: "#{Config.base_url}/create-account")
          end

          flash["notice"] = "Invitation sent successfully to '#{email}'."

          r.redirect "#{@project.path}/user"
        end
      end

      r.on "token" do
        authorize("Project:token", @project.id)

        r.is do
          r.get do
            @tokens = current_account.api_keys
            view "project/token"
          end

          r.post do
            pat = nil
            DB.transaction do
              pat = ApiKey.create_personal_access_token(current_account, project: @project)
              SubjectTag[project_id: @project.id, name: "Admin"].add_subject(pat.id)
            end
            flash["notice"] = "Created personal access token with id #{pat.ubid}"
            r.redirect "#{@project.path}/user/token"
          end
        end

        r.on String do |ubid|
          @token = token = current_account.api_keys_dataset.with_pk(UBID.to_uuid(ubid))

          r.delete true do
            if token
              DB.transaction do
                token.destroy
                @project.disassociate_subject(token.id)
              end
              flash["notice"] = "Personal access token deleted successfully"
            end
            204
          end

          r.is "restrict-access" do
            unless token.unrestricted_token_for_project?(@project.id)
              flash["error"] = "Token access is already restricted"
              r.redirect "#{@project.path}/user/token/#{token.ubid}/access-control"
            end

            r.get do
              view "project/restrict-token"
            end

            r.post do
              token.restrict_token_for_project(@project.id)
              flash["notice"] = "Restricted personal access token"
              r.redirect "#{@project.path}/user/token/#{token.ubid}/access-control"
            end
          end

          r.on "access-control" do
            if token.unrestricted_token_for_project?(@project.id)
              r.redirect "#{@project.path}/user/token/#{token.ubid}/restrict-access"
            end

            r.get true do
              uuids = {}
              aces = @project.access_control_entries_dataset.where(subject_id: token.id).all
              aces.each do |ace|
                uuids[ace.action_id] = nil if ace.action_id
                uuids[ace.object_id] = nil if ace.object_id
              end
              UBID.resolve_map(uuids)
              @aces = aces.map do |ace|
                [ace.ubid, [uuids[ace.action_id], uuids[ace.object_id]], true]
              end
              sort_aces!(@aces)
              view "project/token-access-control"
            end

            r.is "entry", String do |ubid|
              if ubid == "new"
                @ace = AccessControlEntry.new_with_id(project_id: @project.id, subject_id: token.id)
              else
                next unless (@ace = AccessControlEntry[project_id: @project.id, subject_id: token.id, id: UBID.to_uuid(ubid)])
              end

              r.get do
                view "project/access-control-entry"
              end

              r.post do
                was_new = @ace.new?

                action_id, object_id = typecast_params.nonempty_str(%w[action object])
                @ace.update_from_ubids(action_id:, object_id:)

                flash["notice"] = "Token access control entry #{was_new ? "created" : "updated"} successfully"
                r.redirect "#{@project_data[:path]}/user/token/#{token.ubid}/access-control"
              end

              r.delete(!@ace.new?) do
                @ace.destroy
                flash["notice"] = "Token access control entry deleted successfully"
                204
              end
            end
          end
        end
      end

      r.post "policy/managed" do
        authorize("Project:user", @project.id)

        invitation_policies = r.params["invitation_policies"] || {}
        allowed_tags = dataset_authorize(@project.subject_tags_dataset, "SubjectTag:add").select_hash(:name, Sequel.as(true, :v))
        invitation_policies.each do |email, policy|
          if allowed_tags[policy]
            @project.invitations.find { _1.email == email }&.update(policy: policy)
          end
        end

        flash["notice"] = "Subject tags for invited users updated successfully."

        r.redirect "#{@project.path}/user"
      end

      r.on "access-control" do
        r.get true do
          authorize("Project:viewaccess", @project.id)

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

          @subject_options = {nil => [["", "Choose a Subject"]], **SubjectTag.options_for_project(@project)}
          @action_options = {nil => [["", "All Actions"]], **ActionTag.options_for_project(@project)}
          @object_options = {nil => [["", "All Objects"]], **ObjectTag.options_for_project(@project)}

          view "project/access-control"
        end

        r.post true do
          authorize("Project:editaccess", @project.id)

          DB.transaction do
            r.params["aces"].each do
              ubid, deleted, subject_id, action_id, object_id = _1.values_at("ubid", "deleted", "subject", "action", "object")

              next if subject_id == "" || ubid == "template"
              check_ace_subject(UBID.to_uuid(subject_id))

              if ubid == "new"
                next if deleted == "true"
                ace = AccessControlEntry.new_with_id(project_id: @project.id)
              else
                next unless (ace = AccessControlEntry[project_id: @project.id, id: UBID.to_uuid(ubid)])
                check_ace_subject(ace.subject_id)
                if deleted == "true"
                  ace.destroy
                  next
                end
              end
              ace.update_from_ubids(subject_id:, action_id:, object_id:)
            end
          end

          flash["notice"] = "Access control entries saved successfully"

          r.redirect "#{@project_data[:path]}/user/access-control"
        end

        r.on "tag", %w[subject action object] do |tag_type|
          @tag_type = tag_type
          @display_tag_type = tag_type.capitalize
          @tag_model = Object.const_get(:"#{@display_tag_type}Tag")

          r.get true do
            authorize("Project:viewaccess", @project.id)
            @tags = dataset_authorize(@tag_model.where(project_id: @project.id).order(:name), "#{@tag_model}:view").all
            view "project/tag-list"
          end

          r.on String do |ubid|
            if ubid == "new"
              @tag = @tag_model.new_with_id(project_id: @project.id)
              new = true
            else
              next unless (@tag = @tag_model[project_id: @project.id, id: UBID.to_uuid(ubid)])
            end

            r.is do
              authorize(tag_perm_map[tag_type], @project.id)

              if @tag_type == "subject" && @tag.name == "Admin"
                flash["error"] = "Cannot modify Admin subject tag"
                r.redirect "#{@project_data[:path]}/user/access-control/tag/#{@tag_type}"
              end

              r.get do
                view "project/tag"
              end

              r.post do
                @tag.update(name: typecast_params.nonempty_str("name"))
                flash["notice"] = "#{@display_tag_type} tag #{new ? "created" : "name updated"} successfully"
                r.redirect "#{@project_data[:path]}/user/access-control/tag/#{@tag_type}"
              end

              r.delete(!new) do
                @tag.destroy
                flash["notice"] = "#{@display_tag_type} tag deleted successfully"
                204
              end
            end

            r.on !new do
              # Metatag uuid is used to differentiate being allowed to manage
              # tag itself, compared to being able to manage things contained in
              # the tag.
              @authorize_id = (tag_type == "object") ? @tag.metatag_uuid : @tag.id

              r.get "membership" do
                authorize("#{@tag.class}:view", @authorize_id)

                members = @current_members = {}
                @tag.member_ids.each do
                  next if @tag_type == "subject" && UBID.uuid_class_match?(_1, ApiKey)
                  members[_1] = nil
                end
                UBID.resolve_map(members)
                view "project/tag-membership"
              end

              r.post "associate" do
                authorize("#{@tag.class}:add", @authorize_id)

                # Use serializable isolation to try to prevent concurrent changes
                # from introducing loops
                changes_made = to_add = issues = nil
                DB.transaction(isolation: :serializable) do
                  to_add = typecast_params.array(:nonempty_str, "add") || []
                  to_add.reject! { UBID.class_match?(_1, ApiKey) } if @tag_type == "subject"
                  to_add.map! { UBID.to_uuid(_1) }
                  to_add, issues = @tag.check_members_to_add(to_add)
                  issues = "#{": " unless issues.empty?}#{issues.join(", ")}"
                  unless to_add.empty?
                    @tag.add_members(to_add)
                    changes_made = true
                  end
                end

                if changes_made
                  flash["notice"] = "#{to_add.length} members added to #{@tag_type} tag#{issues}"
                else
                  flash["error"] = "No change in membership#{issues}"
                end

                r.redirect "membership"
              end

              r.post "disassociate" do
                authorize("#{@tag.class}:remove", @authorize_id)

                to_remove = typecast_params.array(:nonempty_str, "remove") || []
                to_remove.reject! { UBID.class_match?(_1, ApiKey) } if @tag_type == "subject"
                to_remove.map! { UBID.to_uuid(_1) }

                error = false
                num_removed = nil
                # No need for serializable isolation here, as we are removing
                # entries and that will not introduce loops
                DB.transaction do
                  num_removed = @tag.remove_members(to_remove)

                  if @tag_type == "subject" && @tag.name == "Admin" && !@tag.member_ids.find { UBID.uuid_class_match?(_1, Account) }
                    error = "must keep at least one account in Admin subject tag"
                    DB.rollback_on_exit
                  end
                end

                if error
                  flash["error"] = "Members not removed from tag: #{error}"
                else
                  flash["notice"] = "#{num_removed} members removed from #{@tag_type} tag"
                end

                r.redirect "membership"
              end
            end
          end
        end
      end

      r.delete "invitation", String do |email|
        authorize("Project:user", @project.id)

        @project.invitations_dataset.where(email: email).destroy
        # Javascript handles redirect
        flash["notice"] = "Invitation for '#{email}' is removed successfully."
        204
      end

      r.delete String do |user_ubid|
        authorize("Project:user", @project.id)

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
