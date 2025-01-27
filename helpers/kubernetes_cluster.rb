# frozen_string_literal: true

class Clover
  def kubernetes_cluster_post(name)
    authorize("KubernetesCluster:create", @project.id)

    required_parameters = ["name", "location", "version", "private_subnet_id", "cp_nodes", "worker_nodes"]
    request_body_params = validate_request_params(required_parameters)

    private_subnet = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])

    unless private_subnet && private_subnet.location == @location
      fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" and the location \"#{@location}\" is not found"})
    end

    authorize("PrivateSubnet:edit", private_subnet.id)

    kc = nil

    DB.transaction do
      kc = Prog::Kubernetes::KubernetesClusterNexus.assemble(
        name: name,
        version: request.params["version"],
        private_subnet_id: private_subnet.id,
        project_id: @project.id,
        location: @location,
        cp_node_count: request.params["cp_nodes"].to_i
      ).subject

      Prog::Kubernetes::KubernetesNodepoolNexus.assemble(
        name: name + "-np",
        node_count: request.params["worker_nodes"].to_i,
        kubernetes_cluster_id: kc.id
      )
    end

    flash["notice"] = "'#{name}' will be ready in a few minutes"
    request.redirect "#{@project.path}#{kc.path}"
  end

  def kubernetes_cluster_list
    dataset = dataset_authorize(@project.kubernetes_clusters_dataset, "KubernetesCluster:view").eager(:semaphores, :strand)

    @kcs = Serializers::KubernetesCluster.serialize(dataset.all, {include_path: true})
    view "kubernetes-cluster/index"
  end

  def generate_kubernetes_cluster_options
    options = OptionTreeGenerator.new

    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.kubernetes_locations.map(&:display_name))
    options.add_option(name: "version", values: ["v1.32", "v1.31"])
    options.add_option(name: "cp_nodes", values: ["1", "3"])
    options.add_option(name: "worker_nodes", values: (1..6).map { {value: _1.to_s, display_name: _1.to_s} })

    subnets = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view").map {
      {
        location: LocationNameConverter.to_display_name(_1.location),
        value: _1.ubid,
        display_name: _1.name
      }
    }
    options.add_option(name: "private_subnet_id", values: subnets, parent: "location") do |location, private_subnet|
      private_subnet[:location] == location
    end

    options.serialize
  end
end
