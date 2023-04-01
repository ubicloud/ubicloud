# frozen_string_literal: true

require "ulid"

class Clover
  PageVm = Struct.new(:id, :name, :state, :ip6, keyword_init: true)

  hash_branch("profile") do |r|
    r.get true do
      view "profile/show"
    end
  end
end
