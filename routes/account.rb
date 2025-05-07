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
          @identities = current_account.identities.to_h { [it.provider, it.uid] }

          view "account/login_method"
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
            flash[:notice] = "Your account has been disconnected from #{provider.capitalize}"
          else
            flash[:error] = "Your account already has been disconnected from #{provider.capitalize}"
          end

          r.redirect "/account/login-method"
        end
      end
    end
  end
end
