# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes-cluster") do |r|
    r.get true do
      kubernetes_list
    end

    r.post do
      r.on NAME_OR_UBID do |kc_name, kc_id|
        if kc_name
          post_kubernetes_cluster(kc_name)
        end
      end
    end
  end
end
