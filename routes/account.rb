# frozen_string_literal: true

class Clover
  hash_branch("account") do |r|
    r.web do
      r.get true do
        no_authorization_needed
        r.redirect "/account/multifactor-manage"
      end

      r.on "login-method" do
        r.get true do
          no_authorization_needed
          view "account/login_method"
        end

        r.get "oidc" do
          no_authorization_needed
          handle_validation_failure("account/login_method")
          unless (id = typecast_params.ubid_uuid("provider")) && (oidc_provider = OidcProvider[id])
            raise_web_error("No valid OIDC provider with that ID")
          end

          r.redirect "/auth/#{oidc_provider.ubid}?redirect_url=/account/login-method"
        end

        r.post "disconnect" do
          no_authorization_needed
          no_audit_log
          handle_validation_failure("account/login_method")
          provider, uid = typecast_params.nonempty_str(["provider", "uid"])
          identities = current_account.identities
          unless identities.length > (rodauth.has_password? ? 0 : 1)
            rodauth.add_audit_log(current_account_id, ((provider == "password") ? :remove_password_failure : :disconnect_provider_failure), {"reason" => "only remaining authentication method"})
            raise_web_error("You must have at least one login method")
          end

          DB.transaction do
            if provider == "password"
              DB[:account_password_hashes].where(id: current_account.id).delete
              DB[:account_previous_password_hashes].where(account_id: current_account.id).delete
              rodauth.add_audit_log(current_account_id, :remove_password)
              flash[:notice] = "Your password has been deleted"
            elsif (identity = identities.find { it.provider == provider && it.uid == uid })
              identity.destroy
              rodauth.add_audit_log(current_account_id, :disconnect_provider, {"provider" => omniauth_provider_name(provider)})
              flash[:notice] = "Your account has been disconnected from #{omniauth_provider_name(provider)}"
            else
              raise_web_error("Your account already has been disconnected from #{omniauth_provider_name(provider)}")
            end
          end

          r.redirect "/account/login-method"
        end
      end
    end
  end
end
