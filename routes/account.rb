# frozen_string_literal: true

class Clover
  hash_branch("account") do |r|
    r.web do
      r.get true do
        r.redirect "/account/multifactor-manage"
      end

      r.on "login-method" do
        r.get true do
          @identities = current_account.identities.to_h { [_1.provider, _1.uid] }

          view "account/login_method"
        end

        r.post "disconnect" do
          provider, uid = typecast_params.nonempty_str(["provider", "uid"])
          identities = current_account.identities
          unless identities.length > 1
            # YYYY: We can allow to disconnect the last omniauth provider if the user has a password
            # But need https://github.com/jeremyevans/rodauth/pull/461 to be merged first.
            flash[:error] = "You must have at least one login method"
            r.redirect "/account/login-method"
          end
          if (identity = identities.find { _1.provider == provider && _1.uid == uid })
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
