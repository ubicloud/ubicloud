# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "token") do |r|
    authorize("Project:token", @project)

    r.on "jwt-issuer" do
      r.is do
        r.get do
          if api?
            {items: Serializers::TrustedJwtIssuer.serialize(@project.trusted_jwt_issuers)}
          else
            response.status = 404
            request.halt
          end
        end

        r.post do
          if web?
            token_ds = current_account.api_keys_dataset.where(project_id: @project.id).reverse(:created_at)
            @tokens = token_ds.all
            @jwt_issuers = @project.trusted_jwt_issuers
            handle_validation_failure("project/token")
          end

          name = typecast_body_params.nonempty_str!("name")
          issuer = typecast_body_params.nonempty_str!("issuer")
          jwks_uri = typecast_body_params.nonempty_str!("jwks_uri")
          audience = typecast_body_params.nonempty_str("audience")

          jwt_issuer = nil
          DB.transaction do
            jwt_issuer = TrustedJwtIssuer.create(
              project_id: @project.id,
              account_id: current_account_id,
              name:,
              issuer:,
              jwks_uri:,
              audience:,
            )
            audit_log(jwt_issuer, "create")
          end

          if api?
            Serializers::TrustedJwtIssuer.serialize(jwt_issuer)
          else
            flash["notice"] = "Trusted JWT issuer created"
            r.redirect @project, "/token"
          end
        end
      end

      r.on :ubid_uuid do |uuid|
        jwt_issuer = @project.trusted_jwt_issuers_dataset.with_pk(uuid)
        check_found_object(jwt_issuer)

        r.is web?, "access-control" do
          @jwt_issuer = jwt_issuer

          r.get do
            load_access_control_entries(jwt_issuer)
            view "project/access-control"
          end

          r.post do
            save_access_control_entries(jwt_issuer)
            flash["notice"] = "Trusted JWT issuer access control entries saved successfully"

            r.redirect jwt_issuer
          end
        end

        r.get true do
          if api?
            Serializers::TrustedJwtIssuer.serialize(jwt_issuer)
          else
            response.status = 404
            request.halt
          end
        end

        r.delete true do
          DB.transaction do
            jwt_issuer.destroy
            audit_log(jwt_issuer, "destroy")
          end

          if api?
            204
          else
            flash["notice"] = "Trusted JWT issuer deleted"
            r.redirect @project, "/token"
          end
        end
      end
    end

    r.web do
      token_ds = current_account
        .api_keys_dataset
        .where(project_id: @project.id)
        .reverse(:created_at)

      r.is do
        r.get do
          @tokens = token_ds.all
          @jwt_issuers = @project.trusted_jwt_issuers
          view "project/token"
        end

        r.post do
          pat = nil
          DB.transaction do
            pat = ApiKey.create_personal_access_token(current_account, project: @project)
            @project.subject_tags_dataset.first(name: "Admin").add_subject(pat.id)
            audit_log(pat, "create")
            rodauth.add_audit_log(current_account_id, :create_token, {"token" => pat.ubid})
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
            rodauth.add_audit_log(current_account_id, :delete_token, {"token" => token.ubid})
          end
          flash["notice"] = "Personal access token deleted successfully"
          r.redirect @project, "/token"
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
            load_access_control_entries(token)
            view "project/access-control"
          end

          r.post do
            save_access_control_entries(token)
            flash["notice"] = "Token access control entries saved successfully"

            r.redirect token
          end
        end
      end
    end
  end

  private def load_access_control_entries(subject)
    uuids = {}
    aces = @project.access_control_entries_dataset.where(subject_id: subject.id).all
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
  end

  private def save_access_control_entries(subject)
    DB.transaction do
      DB.ignore_duplicate_queries do
        typecast_params.array!(:Hash, "aces").each do
          ubid, deleted, action_id, object_id = it.values_at("ubid", "deleted", "action", "object")
          action_id = nil if action_id == ""
          object_id = nil if object_id == ""

          if ubid == "template"
            next if deleted == "true" || (action_id.nil? && object_id.nil?)
            ace = AccessControlEntry.new(project_id: @project.id, subject_id: subject.id)
            audit_action = "create"
          else
            next unless (ace = @project.access_control_entries_dataset.first(subject_id: subject.id, id: UBID.to_uuid(ubid)))
            if deleted == "true"
              ace.destroy
              audit_log(ace, "destroy")
              next
            end
            audit_action = "update"
          end
          ace.update_from_ubids(action_id:, object_id:)
          audit_log(ace, audit_action, [subject, action_id, object_id])
        end
      end
    end

    no_audit_log # Possibly no changes
  end
end
