# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "token") do |r|
    r.web do
      authorize("Project:token", @project)
      token_ds = current_account
        .api_keys_dataset
        .where(project_id: @project.id)
        .reverse(:created_at)

      r.is do
        r.get do
          @tokens = token_ds.all
          view "project/token"
        end

        r.post do
          pat = nil
          DB.transaction do
            pat = ApiKey.create_personal_access_token(current_account, project: @project)
            SubjectTag[project_id: @project.id, name: "Admin"].add_subject(pat.id)
            audit_log(pat, "create")
          end
          flash["notice"] = "Created personal access token with id #{pat.ubid}"
          r.redirect @project, "/token"
        end
      end

      r.on :ubid_uuid do |uuid|
        @token = token = token_ds.with_pk(uuid)
        check_found_object(token)

        r.delete true do
          DB.transaction do
            token.destroy
            @project.disassociate_subject(token.id)
            audit_log(token, "destroy")
          end
          flash["notice"] = "Personal access token deleted successfully"
          204
        end

        r.post %w[unrestrict-access restrict-access] do |action|
          DB.transaction do
            if action == "restrict-access"
              token.restrict_token_for_project(@project.id)
              audit_log(token, "restrict")
              flash["notice"] = "Restricted personal access token"
            else
              token.unrestrict_token_for_project(@project.id)
              audit_log(token, "unrestrict")
              flash["notice"] = "Token access is now unrestricted"
            end
          end

          r.redirect token
        end

        r.is "access-control" do
          r.get do
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

            @action_options = {nil => [["", "All Actions"]], **ActionTag.options_for_project(@project)}
            @object_options = {nil => [["", "All Objects"]], **ObjectTag.options_for_project(@project)}

            view "project/access-control"
          end

          r.post do
            DB.transaction do
              typecast_params.array!(:Hash, "aces").each do
                ubid, deleted, action_id, object_id = it.values_at("ubid", "deleted", "action", "object")
                action_id = nil if action_id == ""
                object_id = nil if object_id == ""

                if ubid == "template"
                  next if deleted == "true" || (action_id.nil? && object_id.nil?)
                  ace = AccessControlEntry.new(project_id: @project.id, subject_id: token.id)
                  audit_action = "create"
                else
                  next unless (ace = AccessControlEntry[project_id: @project.id, subject_id: token.id, id: UBID.to_uuid(ubid)])
                  if deleted == "true"
                    ace.destroy
                    audit_log(ace, "destroy")
                    next
                  end
                  audit_action = "update"
                end
                ace.update_from_ubids(action_id:, object_id:)
                audit_log(ace, audit_action, [token, action_id, object_id])
              end
            end

            no_audit_log # Possibly no changes
            flash["notice"] = "Token access control entries saved successfully"

            r.redirect token
          end
        end
      end
    end
  end
end
