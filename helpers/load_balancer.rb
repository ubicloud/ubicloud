# frozen_string_literal: true

class Clover
  def load_balancer_list
    dataset = dataset_authorize(@project.load_balancers_dataset, "LoadBalancer:view")
    dataset = dataset.join(:private_subnet, id: Sequel[:load_balancer][:private_subnet_id]).where(location: @location).select_all(:load_balancer) if @location
    if api?
      result = dataset.paginated_result(
        start_after: request.params["start_after"],
        page_size: request.params["page_size"],
        order_column: request.params["order_column"]
      )

      {
        items: Serializers::LoadBalancer.serialize(result[:records]),
        count: result[:count]
      }
    else
      @lbs = Serializers::LoadBalancer.serialize(dataset.all, {include_path: true})
      view "networking/load_balancer/index"
    end
  end

  def load_balancer_post(name)
    authorize("LoadBalancer:create", @project.id)

    required_parameters = %w[private_subnet_id algorithm src_port dst_port health_check_protocol]
    required_parameters << "name" if web?
    optional_parameters = %w[health_check_endpoint]
    request_body_params = Validation.validate_request_body(json_params, required_parameters, optional_parameters)

    unless (ps = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"]))
      fail Validation::ValidationFailed.new("private_subnet_id" => "Private subnet not found")
    end
    authorize("PrivateSubnet:view", ps.id)

    lb = Prog::Vnet::LoadBalancerNexus.assemble(
      ps.id,
      name:,
      algorithm: request_body_params["algorithm"],
      src_port: Validation.validate_port(:src_port, request_body_params["src_port"]),
      dst_port: Validation.validate_port(:dst_port, request_body_params["dst_port"]),
      health_check_endpoint: request_body_params["health_check_endpoint"],
      health_check_protocol: request_body_params["health_check_protocol"]
    ).subject

    if api?
      Serializers::LoadBalancer.serialize(lb, {detailed: true})
    else
      flash["notice"] = "'#{name}' is created"
      request.redirect "#{@project.path}#{lb.path}"
    end
  end
end
