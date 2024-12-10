# frozen_string_literal: true

class Clover
  def post_kubernetes_cluster(name)
    authorize("KubernetesCluster:create", @project.id)

    st = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: name,
      kubernetes_version: request.params["kubernetes_version"],
      subnet: request.params["subnet"],
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

  def post_kubernetes_vm(name)
    authorize("KubernetesVm:create", @project.id)

    st = Prog::Kubernetes::KubernetesVmNexus.assemble(
      unix_user: request.params["unix_user"],
      project_id: @project.id,
      location: @location,
      name: name,
      size: request.params["size"],
      storage_size: request.params["storage_size"],
      boot_image: request.params["boot_image"],
      private_subnet_id: request.params["private_subnet_id"],
      enable_ip4: request.params["enable_ip4"],
      commands: request.params["commands"]
    )
    Serializers::KubernetesVm.serialize(st.subject)
  end

  def kubernetes_vm_list
    dataset = dataset_authorize(@project.kubernetes_vms_dataset, "KubernetesVm:view")

    if api?
      result = dataset.paginated_result(
        start_after: request.params["start_after"],
        page_size: request.params["page_size"],
        order_column: request.params["order_column"]
      )

      {
        items: Serializers::KubernetesVm.serialize(result[:records]),
        count: result[:count]
      }
    else
      view "kubernetes/vm/index"
    end
  end
end
