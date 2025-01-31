# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "kubernetes-cluster") do |r|
    r.web do
      next unless @project.get_ff_kubernetes

      r.get true do
        kubernetes_cluster_list
      end

      r.post true do
        @location = LocationNameConverter.to_internal_name(r.params["location"])
        kubernetes_cluster_post(r.params["name"])
      end

      r.get "create" do
        authorize("KubernetesCluster:create", @project.id)

        @option_tree, @option_parents = generate_kubernetes_cluster_options

        view "kubernetes-cluster/create"
      end
    end
  end
end
