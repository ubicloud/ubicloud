# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "kubernetes-cluster") do |r|
    r.get true do
      kubernetes_cluster_list
    end

    r.web do
      r.post true do
        handle_validation_failure("kubernetes-cluster/create")
        check_visible_location
        kubernetes_cluster_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("KubernetesCluster:create", @project.id)
        view "kubernetes-cluster/create"
      end
    end
  end
end
