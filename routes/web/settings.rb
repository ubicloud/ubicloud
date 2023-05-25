# frozen_string_literal: true

require "ulid"

class CloverWeb
  hash_branch("settings") do |r|
    r.get true do
      r.redirect "/settings/change-password"
    end
  end
end
