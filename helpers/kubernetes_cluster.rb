# frozen_string_literal: true

class Clover
  def kubernetes_cluster_post(name)
    authorize("KubernetesCluster:create", @project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

    required_parameters = ["name", "location", "cp_nodes", "worker_nodes"]
    request_body_params = validate_request_params(required_parameters)

    DB.transaction do
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
        name: name,
        project_id: @project.id,
        location_id: @location.id,
        cp_node_count: request_body_params["cp_nodes"].to_i
      ).subject

      Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
        name: name + "-np",
        node_count: request_body_params["worker_nodes"].to_i,
        kubernetes_cluster_id: kc.id
      )

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
    options.add_option(name: "cp_nodes", values: Option::KubernetesCPOptions.map(&:cp_node_count), parent: "location")
    options.add_option(name: "worker_nodes", values: (1..10).map { {value: it, display_name: "#{it} Node#{(it == 1) ? "" : "s"}"} }, parent: "cp_nodes") do |location, cp_nodes, worker_nodes|
      worker_nodes[:value] >= cp_nodes
    end

    options.serialize
  end
end
