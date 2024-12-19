# frozen_string_literal: true

class Clover
  def post_kubernetes_cluster(name)
    authorize("KubernetesCluster:create", @project.id)

    required_parameters = ["name", "location", "kubernetes_version", "private_subnet_id"]
    request_body_params = validate_request_params(required_parameters)

    private_subnet = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])

    unless private_subnet && private_subnet.location == @location
      if api?
        fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{private_subnet_id}\" and the location \"#{@location}\" is not found"})
      else
        flash["error"] = "Private subnet not found"
        r.redirect "#{@project.path}/kubernetes-cluster"
      end
    end

    authorize("PrivateSubnet:edit", private_subnet.id)

    st = Prog::Kubernetes::KubernetesClusterNexus.assemble(
      name: name,
      kubernetes_version: request.params["kubernetes_version"],
      private_subnet_id: private_subnet.ubid,
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

  def generate_kubernetes_cluster_options
    options = OptionTreeGenerator.new

    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.kubernetes_locations.map(&:display_name))
    options.add_option(name: "kubernetes_version", values: ["v1.32.0", "v1.31.0"])

    subnets = @project.private_subnets_dataset.authorized(current_account.id, "PrivateSubnet:view").map {
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
