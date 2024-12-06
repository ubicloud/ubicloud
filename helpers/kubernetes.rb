# frozen_string_literal: true

class Clover
  def post_kubernetes(name)
    authorize("KubernetesCluster:create", @project.id)

    st = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: name,
      kubernetes_version: request.params["kubernetes_version"],
      subnet: request.params["subnet"],
      project_id: @project.id,
      location: @location,
      replica: 3
    )
    Serializers::KubernetesCluster.serialize(st.subject)
  end

  def kubernetes_list
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
      view "kubernetes/index"
    end
  end
end
