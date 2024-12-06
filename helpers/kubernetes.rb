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

  def post_kubernetes_vm(name)
    authorize("KubernetesCluster:create", @project.id)

    vm_st = Prog::Vm::Nexus.assemble_with_sshable(
      request.params["unix_user"],
      @project.id,
      location: @location,
      name: name,
      size: request.params["size"],
      storage_volumes: [
        {encrypted: true, size_gib: request.params["storage_size"]}
      ],
      boot_image: request.params["boot_image"],
      private_subnet_id: request.params["private_subnet_id"],
      enable_ip4: request.params["enable_ip4"],
      allow_only_ssh: true
    )

    kubernetes_vm_st = Prog::Kubernetes::KubernetesVmNexus.assemble(vm_st.subject, request.params["commands"])
    Serializers::Vm.serialize(kubernetes_vm_st.subject, {detailed: true})
  end
end
