# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes") do |r|
    r.get true do
      kubernetes_list
    end

    r.post true do
      post_kubernetes
      {}
    end
  end
end
