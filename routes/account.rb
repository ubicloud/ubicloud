# frozen_string_literal: true

class Clover
  hash_branch("account") do |r|
    r.get web? do
      r.redirect "/account/change-password"
    end
  end
end
