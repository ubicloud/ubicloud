# frozen_string_literal: true

require "json"

class Clover
  hash_branch("operation") do |r|
    r.post do
      id = typecast_params.str("id")
      Semaphore.where { request_ids.contains(id) }.select(:name).distinct.all.to_json
    end
  end
end
