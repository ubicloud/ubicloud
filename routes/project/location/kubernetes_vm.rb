# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "kubernetes-vm") do |r|
    r.post do
      r.on api? do
        r.on NAME_OR_UBID do |kv_name, kv_id|
          if kv_name
            post_kubernetes_vm(kv_name)
          end
        end
      end
    end
  end
end
