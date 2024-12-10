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
        authorized_kcs = dataset_authorize(@project.kubernetes_clusters_dataset, "KubernetesCluster:view").all
        authorized_subnets = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view").all
        @kcs = Serializers::KubernetesCluster.serialize(authorized_kcs)
        @subnets = Serializers::PrivateSubnet.serialize(authorized_subnets)
        view "kubernetes-cluster/create"
      end
    end
  end
end
