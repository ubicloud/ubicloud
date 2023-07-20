# frozen_string_literal: true

class CloverWeb
  hash_branch("account") do |r|
    r.get true do
      r.redirect "/account/change-password"
    end
  end
end
