# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "kubernetes-cluster") do |r|
    r.web do
      r.get true do
        kubernetes_cluster_list
      end

      r.post true do
        check_visible_location
        kubernetes_cluster_post(typecast_params.nonempty_str("name"))
      end

      r.get "create" do
        authorize("KubernetesCluster:create", @project.id)

        @has_valid_payment_method = @project.has_valid_payment_method?
        @option_tree, @option_parents = generate_kubernetes_cluster_options

        view "kubernetes-cluster/create"
      end
    end
  end
end
