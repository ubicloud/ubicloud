# frozen_string_literal: true

class Clover
  def kubernetes_cluster_post(name)
    authorize("KubernetesCluster:create", @project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

    params = check_required_web_params(["name", "location", "version", "cp_nodes", "worker_size", "worker_nodes"])

    DB.transaction do
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
        name: name,
        project_id: @project.id,
        location_id: @location.id,
        cp_node_count: params["cp_nodes"].to_i,
        version: params["version"]
      ).subject

      Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
        name: name + "-np",
        node_count: params["worker_nodes"].to_i,
        kubernetes_cluster_id: kc.id,
        target_node_size: params["worker_size"]
      )
      audit_log(kc, "create")

      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect "#{@project.path}#{kc.path}"
    end
  end

  def kubernetes_cluster_list
    @kcs = dataset_authorize(@project.kubernetes_clusters_dataset, "KubernetesCluster:view").all

    view "kubernetes-cluster/index"
  end

  def generate_kubernetes_cluster_options
    options = OptionTreeGenerator.new

    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.kubernetes_locations)
    options.add_option(name: "version", values: Option.kubernetes_versions)
    options.add_option(name: "cp_nodes", values: Option::KubernetesCPOptions.map(&:cp_node_count), parent: "location")
    options.add_option(name: "worker_size", values: Option::VmSizes.select { it.visible && it.vcpus <= 16 }.map { it.display_name }, parent: "location") do |location, size|
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      vm_size.family == "standard"
    end
    options.add_option(name: "worker_nodes", values: (1..10).map { {value: it, display_name: "#{it} Node#{(it == 1) ? "" : "s"}"} }, parent: "worker_size")

    options.serialize
  end
end
