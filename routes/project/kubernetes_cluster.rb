# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "kubernetes-cluster") do |r|
    r.get true do
      kubernetes_cluster_list
    end

    r.on web? do
      r.post true do
        @location = LocationNameConverter.to_internal_name(r.params["location"])
        post_kubernetes_cluster(r.params["name"])
      end

      r.get "create" do
        authorize("KubernetesCluster:create", @project.id)
        authorize("PrivateSubnet:view", @project.id)

        @option_tree, @option_parents = generate_kubernetes_cluster_options

        view "kubernetes-cluster/create"
      end
    end
  end
end
