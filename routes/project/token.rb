# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "token") do |r|
    authorize("Project:token", @project)

    if Config.jwt_issuer_auth
      r.on "jwt-issuer" do
        r.is do
          r.get api? do
            {items: Serializers::JwtIssuer.serialize(@project.jwt_issuers { |ds| ds.where(account_id: current_account_id) })}
          end

          r.post do
            handle_validation_failure("project/token") if web?

            name = typecast_body_params.nonempty_str!("name")
            issuer = typecast_body_params.nonempty_str!("issuer")
            jwks_uri = typecast_body_params.nonempty_str!("jwks_uri")
            audience = typecast_body_params.nonempty_str("audience")

            jwt_issuer = nil
            DB.transaction do
              jwt_issuer = JwtIssuer.create(
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
              Serializers::JwtIssuer.serialize(jwt_issuer)
            else
              flash["notice"] = "JWT issuer created"
              r.redirect @project, "/token"
            end
          end
        end

        r.on :ubid_uuid do |uuid|
          jwt_issuer = @project.jwt_issuers_dataset.where(account_id: current_account_id).with_pk(uuid)
          check_found_object(jwt_issuer)

          r.is web?, "access-control" do
            @jwt_issuer = jwt_issuer

            r.get do
              load_access_control_entries(jwt_issuer)
              view "project/access-control"
            end

            r.post do
              save_access_control_entries(jwt_issuer)
              flash["notice"] = "JWT issuer access control entries saved successfully"

              r.redirect jwt_issuer
            end
          end

          r.get api? do
            Serializers::JwtIssuer.serialize(jwt_issuer)
          end

          r.delete true do
            DB.transaction do
              jwt_issuer.destroy
              audit_log(jwt_issuer, "destroy")
            end

            if api?
              204
            else
              flash["notice"] = "JWT issuer deleted"
              r.redirect @project, "/token"
            end
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
end
