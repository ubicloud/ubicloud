# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get api? do
      load_balancer_list
    end

    r.on NAME_OR_UBID do |lb_name, lb_id|
      filter = if lb_name
        {Sequel[:load_balancer][:name] => lb_name}
      else
        {Sequel[:load_balancer][:id] => UBID.to_uuid(lb_id)}
      end

      filter[:private_subnet_id] = @project.private_subnets_dataset.where(location: @location).select(Sequel[:private_subnet][:id])
      lb = LoadBalancer.first(filter)

      unless lb
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      r.post %w[attach-vm detach-vm] do |action|
        Authorization.authorize(current_account.id, "LoadBalancer:edit", lb.id)
        required_parameters = %w[vm_id]
        request_body_params = Validation.validate_request_body(json_params, required_parameters)
        vm = Vm.from_ubid(request_body_params["vm_id"])

        unless vm
          response.status = 404
          if api?
            r.halt
          else
            flash["error"] = "VM not found"
            r.redirect "#{@project.path}#{lb.path}"
          end
        end

        Authorization.authorize(current_account.id, "Vm:view", vm.id)

        if action == "attach-vm"
          if vm.load_balancer
            flash["error"] = "VM is already attached to a load balancer"
            response.status = 400
            r.redirect "#{@project.path}#{lb.path}"
          end
          lb.add_vm(vm)
          actioned = "attached"
        else
          lb.detach_vm(vm)
          actioned = "detached"
        end

        if api?
          Serializers::LoadBalancer.serialize(lb, {detailed: true})
        else
          flash["notice"] = "VM is #{actioned} from the load balancer"
          r.redirect "#{@project.path}#{lb.path}"
        end
      end

      r.get true do
        Authorization.authorize(current_account.id, "LoadBalancer:view", lb.id)
        @lb = Serializers::LoadBalancer.serialize(lb, {detailed: true, vms_serialized: !api?})
        if api?
          @lb
        else
          vms = lb.private_subnet.vms_dataset.authorized(current_account.id, "Vm:view").exclude(Sequel[:vm][:id] => lb.vms_dataset.select(Sequel[:vm][:id])).all
          @attachable_vms = Serializers::Vm.serialize(vms)

          view "networking/load_balancer/show"
        end
      end

      r.delete true do
        Authorization.authorize(current_account.id, "LoadBalancer:delete", lb.id)
        lb.incr_destroy
        response.status = 204
        r.halt
      end

      r.patch api? do
        Authorization.authorize(current_account.id, "LoadBalancer:edit", lb.id)
        request_body_params = Validation.validate_request_body(json_params, %w[algorithm src_port dst_port health_check_endpoint vms])
        lb.update(
          algorithm: request_body_params["algorithm"],
          src_port: Validation.validate_port(:src_port, request_body_params["src_port"]),
          dst_port: Validation.validate_port(:dst_port, request_body_params["dst_port"]),
          health_check_endpoint: request_body_params["health_check_endpoint"]
        )

        request_body_params["vms"].each do |vm_id|
          vm_id = vm_id.delete("\"")
          vm = Vm.from_ubid(vm_id)
          unless vm
            response.status = 404
            r.halt
          end

          Authorization.authorize(current_account.id, "Vm:view", vm.id)
          if vm.load_balancer && vm.load_balancer.id != lb.id
            fail Validation::ValidationFailed.new("vm_id" => "VM is already attached to a load balancer")
          elsif vm.load_balancer && vm.load_balancer.id == lb.id
            next
          end

          lb.add_vm(vm)
        end

        lb.vms.map { _1.ubid }.reject { request_body_params["vms"].map { |vm_id| vm_id.delete("\"") }.include?(_1) }.each do |vm_id|
          vm = Vm.from_ubid(vm_id)
          lb.evacuate_vm(vm)
          lb.remove_vm(vm)
        end

        response.status = 200
        lb.incr_update_load_balancer
        Serializers::LoadBalancer.serialize(lb.reload, {detailed: true})
      end
    end

    # 204 response for invalid names
    r.is String do |lb_name|
      r.delete do
        response.status = 204
        nil
      end
    end
  end

  hash_branch(:api_project_location_prefix, "load-balancer", &branch)
  hash_branch(:project_location_prefix, "load-balancer", &branch)
end
