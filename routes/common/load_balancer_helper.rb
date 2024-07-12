# frozen_string_literal: true

class Routes::Common::LoadBalancerHelper < Routes::Common::Base
  def list
    lbs = Serializers::LoadBalancer.serialize(project.load_balancers_dataset.authorized(@user.id, "LoadBalancer:view").all, {include_path: true})
    @app.instance_variable_set(:@lbs, lbs)
    @app.view "networking/load_balancer/index"
  end

  def post(name: nil)
    Authorization.authorize(@user.id, "LoadBalancer:create", project.id)

    required_parameters = %w[name private_subnet_id algorithm src_port dst_port health_check_endpoint]
    allowed_optional_parameters = %w[health_check_interval health_check_timeout health_check_up_threshold health_check_down_threshold]
    request_body_params = Validation.validate_request_body(params, required_parameters, allowed_optional_parameters)

    ps = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
    Authorization.authorize(@user.id, "PrivateSubnet:view", ps.id)

    lb = Prog::Vnet::LoadBalancerNexus.assemble(
      ps.id,
      name: name,
      algorithm: request_body_params["algorithm"],
      src_port: Validation.validate_port(:src_port, request_body_params["src_port"]),
      dst_port: Validation.validate_port(:dst_port, request_body_params["dst_port"]),
      health_check_endpoint: request_body_params["health_check_endpoint"],
      health_check_interval: Validation.validate_health_check_parameter(:health_check_interval, request_body_params["health_check_interval"]),
      health_check_timeout: Validation.validate_health_check_parameter(:health_check_timeout, request_body_params["health_check_timeout"]),
      health_check_up_threshold: Validation.validate_health_check_parameter(:health_check_up_threshold, request_body_params["health_check_up_threshold"]),
      health_check_down_threshold: Validation.validate_health_check_parameter(:health_check_down_threshold, request_body_params["health_check_down_threshold"])
    ).subject

    flash["notice"] = "'#{name}' is created"

    @request.redirect "#{project.path}#{lb.path}"
  end

  def get
    Authorization.authorize(@user.id, "LoadBalancer:view", @resource.id)
    vms = @resource.private_subnet.vms_dataset.authorized(@user.id, "Vm:view").all
    attached_vm_ids = @resource.vms.map(&:id)
    @app.instance_variable_set(:@attachable_vms, Serializers::Vm.serialize(vms.reject { attached_vm_ids.include?(_1.id) }))
    @app.instance_variable_set(:@lb, Serializers::LoadBalancer.serialize(@resource, {detailed: true}))

    @app.view "networking/load_balancer/show"
  end

  def delete
    Authorization.authorize(@user.id, "LoadBalancer:delete", @resource.id)

    @resource.incr_destroy
    response.status = 204
    @request.halt
  end

  def post_attach_vm
    Authorization.authorize(@user.id, "LoadBalancer:edit", @resource.id)
    required_parameters = %w[vm_id]
    request_body_params = Validation.validate_request_body(params, required_parameters)
    vm = Vm.from_ubid(request_body_params["vm_id"])
    unless vm
      flash["error"] = "VM not found"
      response.status = 404
      @request.redirect "#{project.path}#{@resource.path}"
    end

    Authorization.authorize(@user.id, "Vm:view", vm.id)

    if vm.load_balancer
      flash["error"] = "VM is already attached to a load balancer"
      response.status = 400
      @request.redirect "#{project.path}#{@resource.path}"
    end

    @resource.add_vm(vm)
    flash["notice"] = "VM is attached"
    @request.redirect "#{project.path}#{@resource.path}"
  end

  def post_detach_vm
    Authorization.authorize(@user.id, "LoadBalancer:edit", @resource.id)
    required_parameters = %w[vm_id]
    request_body_params = Validation.validate_request_body(params, required_parameters)
    vm = Vm.from_ubid(request_body_params["vm_id"])
    unless vm
      flash["error"] = "VM not found"
      response.status = 404
      @request.redirect "#{project.path}#{@resource.path}"
    end

    Authorization.authorize(@user.id, "Vm:view", vm.id)

    @resource.evacuate_vm(vm)
    @resource.remove_vm(vm)
    flash["notice"] = "VM is detached"
    @request.redirect "#{project.path}#{@resource.path}"
  end

  def view_create_page
    Authorization.authorize(@user.id, "LoadBalancer:create", project.id)
    authorized_subnets = project.private_subnets_dataset.authorized(@user.id, "PrivateSubnet:view").all
    @app.instance_variable_set(:@subnets, Serializers::PrivateSubnet.serialize(authorized_subnets))
    @app.view "networking/load_balancer/create"
  end
end
