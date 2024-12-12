# frozen_string_literal: true

class Clover
  def post_kubernetes_cluster(name)
    authorize("KubernetesCluster:create", @project.id)

    st = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: name,
      kubernetes_version: request.params["kubernetes_version"],
      private_subnet_id: request.params["private_subnet_id"],
      project_id: @project.id,
      location: @location,
      replica: 3
    )
    if api?
      Serializers::KubernetesCluster.serialize(st.subject)
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect "#{@project.path}#{KubernetesCluster[st.id].path}"
    end
  end

  def kubernetes_cluster_list
    dataset = dataset_authorize(@project.kubernetes_clusters_dataset, "KubernetesCluster:view")

    if api?
      dataset = dataset.where(location: @location) if @location
      result = dataset.paginated_result(
        start_after: request.params["start_after"],
        page_size: request.params["page_size"],
        order_column: request.params["order_column"]
      )

      {
        items: Serializers::KubernetesCluster.serialize(result[:records]),
        count: result[:count]
      }
    else
      @kcs = Serializers::KubernetesCluster.serialize(dataset.all, {include_path: true})
      view "kubernetes-cluster/index"
    end
  end
end
