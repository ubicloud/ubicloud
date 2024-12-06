# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes") do |r|
    r.get true do
      kubernetes_list
    end

    r.post do
      r.on NAME_OR_UBID do |lb_name, lb_id|
        if lb_name
          post_kubernetes(lb_name)
        end
      end
    end
  end
end
