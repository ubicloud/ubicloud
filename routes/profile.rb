# frozen_string_literal: true

require "ulid"

class Clover
  hash_branch("profile") do |r|
    r.get true do
      view "profile/show"
    end
  end
end
