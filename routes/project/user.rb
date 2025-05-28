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
          @users = @project.accounts_dataset.order_by(:email).all
          @subject_tag_map = SubjectTag.subject_id_map_for_project_and_accounts(@project.id, @users.map(&:id))
          @allowed_view_tag_names = dataset_authorize(@project.subject_tags_dataset, "SubjectTag:view").map(:name)
          @allowed_add_tag_names_map = dataset_authorize(@project.subject_tags_dataset, "SubjectTag:add").select_hash(:name, Sequel.as(true, :v))
          @allowed_remove_tag_names_map = dataset_authorize(@project.subject_tags_dataset, "SubjectTag:remove").select_hash(:name, Sequel.as(true, :v))
          @invitations = @project.invitations_dataset.order_by(:email).all
          view "project/user"
        end

        r.post do
          email = typecast_params.nonempty_str!("email")

          if ProjectInvitation[project_id: @project.id, email: email]
            flash["error"] = "'#{email}' already invited to join the project."
            r.redirect "#{@project.path}/user"
          elsif @project.invitations_dataset.count >= 50
            flash["error"] = "You can't have more than 50 pending invitations."
            r.redirect "#{@project.path}/user"
          end

          if (policy = typecast_params.nonempty_str("policy"))
            unless (tag = dataset_authorize(@project.subject_tags_dataset, "SubjectTag:add").first(name: policy))
              flash["error"] = "You don't have permission to invite users with this subject tag."
              r.redirect "#{@project_data[:path]}/user"
            end
          end

          user = Account.exclude(status_id: 3)[email: email]

          DB.transaction do
            if user
              result = DB[:access_tag]
                .returning(:hyper_tag_id)
                .insert_conflict
                .insert(hyper_tag_id: user.id, project_id: @project.id)
              audit_log(@project, "add_account", user)

              if result.empty?
                flash["error"] = "The requested user already has access to this project"
                r.redirect "#{@project.path}/user"
              end

              if tag
                tag.add_subject(user.id)
                audit_log(tag, "add_member", user)
              end

              Util.send_email(email, "Invitation to Join '#{@project.name}' Project on Ubicloud",
                greeting: "Hello,",
                body: ["You're invited by '#{current_account.name}' to join the '#{@project.name}' project on Ubicloud.",
                  "To join project, click the button below.",
                  "For any questions or assistance, reach out to our team at support@ubicloud.com."],
                button_title: "Join Project",
                button_link: "#{Config.base_url}#{@project.path}/dashboard")
            else
              @project.add_invitation(email: email, policy: (policy if tag), inviter_id: current_account_id, expires_at: Time.now + 7 * 24 * 60 * 60)
              audit_log(@project, "add_invitation")

              Util.send_email(email, "Invitation to Join '#{@project.name}' Project on Ubicloud",
                greeting: "Hello,",
                body: ["You're invited by '#{current_account.name}' to join the '#{@project.name}' project on Ubicloud.",
                  "To join project, you need to create an account on Ubicloud. Once you create an account, you'll be automatically joined to the project.",
                  "For any questions or assistance, reach out to our team at support@ubicloud.com."],
                button_title: "Create Account",
                button_link: "#{Config.base_url}/create-account")
            end
          end

          flash["notice"] = "Invitation sent successfully to '#{email}'."

          r.redirect "#{@project.path}/user"
        end
      end

      r.post "policy/managed" do
        authorize("Project:user", @project.id)
        user_policies = typecast_params.Hash("user_policies") || {}
        invitation_policies = typecast_params.Hash("invitation_policies") || {}
        user_policies.transform_keys! { UBID.to_uuid(it) }
        account_ids = user_policies.keys

        DB.transaction do
          allowed_add_tags = dataset_authorize(@project.subject_tags_dataset, "SubjectTag:add").to_hash(:name)
          allowed_remove_tags = dataset_authorize(@project.subject_tags_dataset, "SubjectTag:remove").to_hash(:name)
          project_account_ids = @project
            .accounts_dataset
            .where(Sequel[:accounts][:id] => account_ids)
            .select_map(Sequel[:accounts][:id])
          subject_tag_map = SubjectTag.subject_id_map_for_project_and_accounts(@project.id, project_account_ids)
          project_account_ids.each do |account_id|
            subject_tag_map[account_id] ||= [] # Handle accounts not in any tags
          end
          additions = {}
          removals = {}
          issues = []

          user_policies.each do |account_id, policy|
            unless (existing_tags = subject_tag_map[account_id])
              issues << "Cannot change the policy for user, as they are not associated to project"
              next
            end
            unless existing_tags.length < 2
              issues << "Cannot change the policy for user, as they are in multiple subject tags"
              next
            end
            policy = nil if policy == ""
            next if existing_tags.include?(policy)
            unless (added_tag = allowed_add_tags[policy]) || !policy
              issues << "You don't have permission to add members to '#{policy}' tag"
              next
            end
            if (tag = existing_tags.first)
              unless (removed_tag = allowed_remove_tags[tag])
                issues << "You don't have permission to remove members from '#{tag}' tag"
                next
              end
              (removals[removed_tag] ||= []) << account_id
            end
            (additions[added_tag] ||= []) << account_id if added_tag
          end

          additions.each do |tag, user_ids|
            tag.add_members(user_ids)
            audit_log(tag, "add_member", user_ids)
          end
          removals.each do |tag, user_ids|
            tag.remove_members(user_ids)
            audit_log(tag, "remove_member", user_ids)
          end
          additions.transform_keys!(&:name)
          removals.transform_keys!(&:name)

          if @project.subject_tags_dataset.first(name: "Admin").member_ids.empty?
            flash["error"] = "The project must have at least one admin."
            DB.rollback_on_exit
            r.redirect "#{@project.path}/user"
          end

          invitatation_map = @project
            .invitations_dataset
            .where(email: invitation_policies.keys)
            .to_hash(:email)
          invitation_policy_changes = {}
          invitation_policies.each do |email, policy|
            policy = nil if policy == ""
            next unless (inv = invitatation_map[email])
            old_policy = inv.policy
            next if policy == old_policy
            if policy && !allowed_add_tags[policy]
              issues << "You don't have permission to add invitation to '#{policy}' tag"
              next
            end
            if old_policy && !allowed_remove_tags[old_policy]
              issues << "You don't have permission to remove invitation from '#{old_policy}' tag"
              next
            end
            (invitation_policy_changes[policy] ||= []) << inv.email
            (additions[policy] ||= []) << 1 if policy
            (removals[old_policy] ||= []) << 1 if old_policy
          end
          invitation_policy_changes.each do |policy, emails|
            @project
              .invitations_dataset
              .where(email: emails)
              .update(policy:)

            audit_log(@project, "update_invitation")
          end

          changes = []
          additions.each { |name, user_ids| changes << "#{user_ids.size} members added to #{name}" }
          removals.each { |name, user_ids| changes << "#{user_ids.size} members removed from #{name}" }

          no_audit_log if changes.empty?
          flash["notice"] = changes.empty? ? "No change in user policies" : changes.join(", ")
          flash["error"] = issues.uniq.join(", ") unless issues.empty?
        end

        r.redirect "#{@project.path}/user"
      end

      r.on "access-control" do
        r.is do
          r.get do
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

          r.post do
            authorize("Project:editaccess", @project.id)

            DB.transaction do
              typecast_params.array!(:Hash, "aces").each do
                ubid, deleted, subject_id, action_id, object_id = it.values_at("ubid", "deleted", "subject", "action", "object")
                subject_id = nil if subject_id == ""
                action_id = nil if action_id == ""
                object_id = nil if object_id == ""

                next unless subject_id
                check_ace_subject(UBID.to_uuid(subject_id)) unless deleted

                if ubid == "template"
                  next if deleted == "true"
                  ace = AccessControlEntry.new_with_id(project_id: @project.id)
                  audit_action = "create"
                else
                  next unless (ace = AccessControlEntry[project_id: @project.id, id: UBID.to_uuid(ubid)])
                  check_ace_subject(ace.subject_id)
                  if deleted == "true"
                    ace.destroy
                    audit_log(ace, "destroy")
                    next
                  end
                  audit_action = "update"
                end
                ace.update_from_ubids(subject_id:, action_id:, object_id:)
                audit_log(ace, audit_action, [subject_id, action_id, object_id])
              end
            end

            flash["notice"] = "Access control entries saved successfully"

            r.redirect "#{@project_data[:path]}/user/access-control"
          end
        end

        r.on "tag", %w[subject action object] do |tag_type|
          @tag_type = tag_type
          @display_tag_type = tag_type.capitalize
          @tag_model = Object.const_get(:"#{@display_tag_type}Tag")

          r.is do
            r.get do
              authorize("Project:viewaccess", @project.id)
              @tags = dataset_authorize(@tag_model.where(project_id: @project.id).order(:name), "#{@tag_model}:view").all
              view "project/tag-list"
            end

            r.post do
              authorize(tag_perm_map[tag_type], @project.id)
              DB.transaction do
                tag = @tag_model.create_with_id(project_id: @project.id, name: typecast_params.nonempty_str("name"))
                audit_log(tag, "create")
              end
              flash["notice"] = "#{@display_tag_type} tag created successfully"
              r.redirect "#{@project_data[:path]}/user/access-control/tag/#{@tag_type}"
            end
          end

          r.on String do |ubid|
            next unless (@tag = @tag_model[project_id: @project.id, id: UBID.to_uuid(ubid)])
            # Metatag uuid is used to differentiate being allowed to manage
            # tag itself, compared to being able to manage things contained in
            # the tag.
            @authorize_id = (tag_type == "object") ? @tag.metatag_uuid : @tag.id

            r.is do
              r.get true do
                authorize("#{@tag.class}:view", @authorize_id)

                members = @current_members = {}
                @tag.member_ids.each do
                  next if @tag_type == "subject" && UBID.uuid_class_match?(it, ApiKey)
                  members[it] = nil
                end
                UBID.resolve_map(members)
                view "project/tag"
              end

              authorize(tag_perm_map[tag_type], @project.id)

              if @tag_type == "subject" && @tag.name == "Admin"
                flash["error"] = "Cannot modify Admin subject tag"
                r.redirect "#{@project_data[:path]}/user/access-control/tag/#{@tag_type}"
              end

              r.post do
                @tag.update(name: typecast_params.nonempty_str("name"))
                audit_log(@tag, "update")
                flash["notice"] = "#{@display_tag_type} tag name updated successfully"
                r.redirect "#{@project_data[:path]}/user/access-control/tag/#{@tag_type}/#{@tag.ubid}"
              end

              r.delete do
                @tag.destroy
                audit_log(@tag, "destroy")
                flash["notice"] = "#{@display_tag_type} tag deleted successfully"
                204
              end
            end

            r.post "associate" do
              authorize("#{@tag.class}:add", @authorize_id)

              # Use serializable isolation to try to prevent concurrent changes
              # from introducing loops
              changes_made = to_add = issues = nil
              DB.transaction(isolation: :serializable) do
                to_add = typecast_params.array(:nonempty_str, "add") || []
                to_add.reject! { UBID.class_match?(it, ApiKey) } if @tag_type == "subject"
                to_add.map! { UBID.to_uuid(it) }
                to_add, issues = @tag.check_members_to_add(to_add)
                issues = "#{": " unless issues.empty?}#{issues.join(", ")}"
                unless to_add.empty?
                  @tag.add_members(to_add)
                  audit_log(@tag, "add_member", to_add)
                  changes_made = true
                end
              end

              if changes_made
                flash["notice"] = "#{to_add.length} members added to #{@tag_type} tag#{issues}"
              else
                flash["error"] = "No change in membership#{issues}"
              end

              r.redirect "#{@project_data[:path]}/user/access-control/tag/#{@tag_type}/#{@tag.ubid}"
            end

            r.post "disassociate" do
              authorize("#{@tag.class}:remove", @authorize_id)

              to_remove = typecast_params.array(:nonempty_str, "remove") || []
              to_remove.reject! { UBID.class_match?(it, ApiKey) } if @tag_type == "subject"
              to_remove.map! { UBID.to_uuid(it) }

              num_removed = nil
              # No need for serializable isolation here, as we are removing
              # entries and that will not introduce loops
              DB.transaction do
                num_removed = @tag.remove_members(to_remove)
                audit_log(@tag, "remove_member", to_remove)

                if @tag_type == "subject" && @tag.name == "Admin" && !@tag.member_ids.find { UBID.uuid_class_match?(it, Account) }
                  raise Sequel::ValidationFailed, "Must keep at least one account in Admin subject tag"
                end
              end

              flash["notice"] = "#{num_removed} members removed from #{@tag_type} tag"
              r.redirect "#{@project_data[:path]}/user/access-control/tag/#{@tag_type}/#{@tag.ubid}"
            end
          end
        end
      end

      r.delete "invitation", String do |email|
        authorize("Project:user", @project.id)

        @project.invitations_dataset.where(email: email).destroy
        audit_log(@project, "destroy_invitation")
        # Javascript handles redirect
        flash["notice"] = "Invitation for '#{email}' is removed successfully."
        204
      end

      r.delete :ubid_uuid do |id|
        authorize("Project:user", @project.id)

        next unless (user = @project.accounts_dataset[id:])

        unless @project.accounts_dataset.count > 1
          response.status = 400
          next {error: {message: "You can't remove the last user from '#{@project.name}' project. Delete project instead."}}
        end

        @project.disassociate_subject(user.id)
        user.remove_project(@project)
        audit_log(@project, "remove_account", user)

        # Javascript refreshes page
        flash["notice"] = "Removed #{user.email} from #{@project.name}"
        204
      end
    end
  end
end
