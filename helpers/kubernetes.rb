# frozen_string_literal: true

class Clover
  def post_kubernetes
    authorize("Kuberenetes:create", @project.id)

    st = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: request.params["name"],
      kubernetes_version: request.params["kubernetes_version"],
      subnet: request.params["subnet"],
      project_id: @project.id,
      location: @location,
      replica: 3
    )
    {}
    # Serializers::KubernetesCluster.serialize(st.subject)
  end

  def kubernetes_list
    if api?
      {}
      # dataset = dataset_authorize(@project.kuberentes_clusters_dataset, "KubernetesCluster:view")
      # dataset = dataset.where(location: @location) if @location
      # result = dataset.paginated_result(
      #   start_after: request.params["start_after"],
      #   page_size: request.params["page_size"],
      #   order_column: request.params["order_column"]
      # )

      # {
      #   items: Serializers::KubernetesCluster.serialize(result[:records]),
      #   count: result[:count]
      # }
    else
      view "kubernetes/index"
    end
  end
end
