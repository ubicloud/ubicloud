# frozen_string_literal: true

class Routes::Common::LoadBalancerHelper < Routes::Common::Base
  def list
    dataset = project.load_balancers_dataset
    dataset = dataset.join(:private_subnet, id: Sequel[:load_balancer][:private_subnet_id]).where(location: @location).select_all(:load_balancer) if @location
    if @mode == AppMode::API
      result = dataset.authorized(@user.id, "LoadBalancer:view").paginated_result(
        start_after: @request.params["start_after"],
        page_size: @request.params["page_size"],
        order_column: @request.params["order_column"]
      )

      {
        items: Serializers::LoadBalancer.serialize(result[:records]),
        count: result[:count]
      }
    else
      lbs = Serializers::LoadBalancer.serialize(dataset.authorized(@user.id, "LoadBalancer:view").all, {include_path: true})
      @app.instance_variable_set(:@lbs, lbs)
      @app.view "networking/load_balancer/index"
    end
  end

  def post(name: nil)
    Authorization.authorize(@user.id, "LoadBalancer:create", project.id)

    required_parameters = %w[private_subnet_id algorithm src_port dst_port health_check_protocol]
    required_parameters << "name" if @mode == AppMode::WEB
    optional_parameters = %w[health_check_endpoint]
    request_body_params = Validation.validate_request_body(params, required_parameters, optional_parameters)

    ps = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
    unless ps
      response.status = 404
      if @mode == AppMode::API
        @request.halt
      else
        flash["error"] = "Private subnet not found"
        @request.redirect "#{project.path}/load-balancer/create"
      end
    end
    Authorization.authorize(@user.id, "PrivateSubnet:view", ps.id)

    lb = Prog::Vnet::LoadBalancerNexus.assemble(
      ps.id,
      name: name,
      algorithm: request_body_params["algorithm"],
      src_port: Validation.validate_port(:src_port, request_body_params["src_port"]),
      dst_port: Validation.validate_port(:dst_port, request_body_params["dst_port"]),
      health_check_endpoint: request_body_params["health_check_endpoint"],
      health_check_protocol: request_body_params["health_check_protocol"]
    ).subject

    if @mode == AppMode::API
      Serializers::LoadBalancer.serialize(lb, {detailed: true})
    else
      flash["notice"] = "'#{name}' is created"
      @request.redirect "#{project.path}#{lb.path}"
    end
  end
end
