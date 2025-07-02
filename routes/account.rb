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
          @identities = current_account.identities_dataset.select_hash(:provider, :uid)
          social_login_providers = omniauth_providers.map { |provider,| provider.to_s }
          @oidc_identities = @identities.reject { |provider,| social_login_providers.include?(provider) }
          @oidc_identity_names = OidcProvider.where(id: @oidc_identities.keys.map! { UBID.to_uuid(it) }).select_hash(:id, :display_name)

          view "account/login_method"
        end

        r.get "oidc" do
          no_authorization_needed
          unless (id = typecast_params.ubid_uuid("provider")) && (oidc_provider = OidcProvider[id])
            flash[:error] = "No valid OIDC provider with that ID"
            r.redirect "/account/login-method"
          end

          r.redirect "/auth/#{oidc_provider.ubid}?redirect_url=/account/login-method"
        end

        r.post "disconnect" do
          no_authorization_needed
          no_audit_log
          provider, uid = typecast_params.nonempty_str(["provider", "uid"])
          identities = current_account.identities
          unless identities.length > (rodauth.has_password? ? 0 : 1)
            flash[:error] = "You must have at least one login method"
            r.redirect "/account/login-method"
          end
          if provider == "password"
            DB[:account_password_hashes].where(id: current_account.id).delete
            DB[:account_previous_password_hashes].where(account_id: current_account.id).delete
            flash[:notice] = "Your password has been deleted"
          elsif (identity = identities.find { it.provider == provider && it.uid == uid })
            identity.destroy
            flash[:notice] = "Your account has been disconnected from #{omniauth_provider_name(provider)}"
          else
            flash[:error] = "Your account already has been disconnected from #{omniauth_provider_name(provider)}"
          end

          r.redirect "/account/login-method"
        end
      end
    end
  end
end
