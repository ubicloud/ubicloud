# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    lb_endpoint_helper = Routes::Common::LoadBalancerHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil)

    r.get api? do
      lb_endpoint_helper.list
    end

    r.on NAME_OR_UBID do |lb_name, lb_id|
      filter = if lb_name
        {Sequel[:load_balancer][:name] => lb_name}
      else
        {Sequel[:load_balancer][:id] => UBID.to_uuid(lb_id)}
      end

      filter[:private_subnet_id] = @project.private_subnets_dataset.where(location: @location).select(Sequel[:private_subnet][:id])
      lb = LoadBalancer.first(filter)
      lb_endpoint_helper.instance_variable_set(:@resource, lb)

      unless lb
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      r.post "attach-vm" do
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

        if vm.load_balancer
          flash["error"] = "VM is already attached to a load balancer"
          response.status = 400
          r.redirect "#{@project.path}#{lb.path}"
        end

        lb.add_vm(vm)

        if api?
          Serializers::LoadBalancer.serialize(lb, {detailed: true})
        else
          flash["notice"] = "VM is attached"
          r.redirect "#{@project.path}#{lb.path}"
        end
      end

      r.post "detach-vm" do
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

        lb.detach_vm(vm)

        if api?
          Serializers::LoadBalancer.serialize(lb, {detailed: true})
        else
          flash["notice"] = "VM is detached"
          r.redirect "#{@project.path}#{lb.path}"
        end
      end

      r.get true do
        Authorization.authorize(current_account.id, "LoadBalancer:view", lb.id)
        @lb = Serializers::LoadBalancer.serialize(lb, {detailed: true, vms_serialized: !api?})
        if api?
          @lb
        else
          vms = lb.private_subnet.vms_dataset.authorized(current_account.id, "Vm:view").all
          attached_vm_ids = lb.vms.map(&:id)
          @attachable_vms = Serializers::Vm.serialize(vms.reject { attached_vm_ids.include?(_1.id) })

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
        lb_endpoint_helper.patch
      end
    end
  end

  hash_branch(:api_project_location_prefix, "load-balancer", &branch)
  hash_branch(:project_location_prefix, "load-balancer", &branch)
end
