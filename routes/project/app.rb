# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "app") do |r|
    r.get true do
      app_process_list
    end
  end
end
