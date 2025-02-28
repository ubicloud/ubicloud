# frozen_string_literal: true

class Clover
  def load_balancer_list
    dataset = dataset_authorize(@project.load_balancers_dataset, "LoadBalancer:view").eager(:private_subnet)
    dataset = dataset.join(:private_subnet, id: Sequel[:load_balancer][:private_subnet_id]).where(location_id: @location.id).select_all(:load_balancer) if @location
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

    required_parameters = %w[private_subnet_id algorithm src_port dst_port health_check_protocol stack]
    required_parameters << "name" if web?
    optional_parameters = %w[health_check_endpoint]
    request_body_params = validate_request_params(required_parameters, optional_parameters)

    unless (ps = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"]))
      fail Validation::ValidationFailed.new("private_subnet_id" => "Private subnet not found")
    end
    authorize("PrivateSubnet:view", ps.id)

    lb = Prog::Vnet::LoadBalancerNexus.assemble(
      ps.id,
      name:,
      algorithm: request_body_params["algorithm"],
      stack: Validation.validate_load_balancer_stack(request_body_params["stack"]),
      src_port: Validation.validate_port(:src_port, request_body_params["src_port"]),
      dst_port: Validation.validate_port(:dst_port, request_body_params["dst_port"]),
      health_check_endpoint: request_body_params["health_check_endpoint"] || Prog::Vnet::LoadBalancerNexus::DEFAULT_HEALTH_CHECK_ENDPOINT,
      health_check_protocol: request_body_params["health_check_protocol"]
    ).subject

    if api?
      Serializers::LoadBalancer.serialize(lb, {detailed: true})
    else
      flash["notice"] = "'#{name}' is created"
      request.redirect "#{@project.path}#{lb.path}"
    end
  end

  def generate_load_balancer_options
    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "description")
    options.add_option(name: "private_subnet_id", values: dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view").map { {value: _1.ubid, display_name: _1.name} })
    options.add_option(name: "algorithm", values: ["Round Robin", "Hash Based"].map { {value: _1.downcase.tr(" ", "_"), display_name: _1} })
    options.add_option(name: "stack", values: [LoadBalancer::Stack::IPV4, LoadBalancer::Stack::IPV6, LoadBalancer::Stack::DUAL].map { {value: _1.downcase, display_name: _1.gsub("ip", "IP")} })
    options.add_option(name: "src_port")
    options.add_option(name: "dst_port")
    options.add_option(name: "health_check_endpoint")
    options.add_option(name: "health_check_protocol", values: ["http", "https", "tcp"].map { {value: _1, display_name: _1.upcase} })
    options.serialize
  end
end
