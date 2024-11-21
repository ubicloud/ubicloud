# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "load-balancer") do |r|
    r.get api? do
      load_balancer_list
    end

    r.on NAME_OR_UBID do |lb_name, lb_id|
      if lb_name
        r.post api? do
          load_balancer_post(lb_name)
        end

        filter = {Sequel[:load_balancer][:name] => lb_name}
      else
        filter = {Sequel[:load_balancer][:id] => UBID.to_uuid(lb_id)}
      end

      filter[:private_subnet_id] = @project.private_subnets_dataset.where(location: @location).select(Sequel[:private_subnet][:id])
      lb = LoadBalancer.first(filter)

      unless lb
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      r.post %w[attach-vm detach-vm] do |action|
        authorize("LoadBalancer:edit", lb.id)
        required_parameters = %w[vm_id]
        request_body_params = Validation.validate_request_body(json_params, required_parameters)

        unless (vm = Vm.from_ubid(request_body_params["vm_id"]))
          fail Validation::ValidationFailed.new("vm_id" => "VM not found")
        end

        authorize("Vm:view", vm.id)

        if action == "attach-vm"
          if vm.load_balancer
            fail Validation::ValidationFailed.new("vm_id" => "VM is already attached to a load balancer")
          end
          lb.add_vm(vm)
          actioned = "attached to"
        else
          lb.detach_vm(vm)
          actioned = "detached from"
        end

        if api?
          Serializers::LoadBalancer.serialize(lb, {detailed: true})
        else
          flash["notice"] = "VM is #{actioned} the load balancer"
          r.redirect "#{@project.path}#{lb.path}"
        end
      end

      r.get true do
        authorize("LoadBalancer:view", lb.id)
        @lb = Serializers::LoadBalancer.serialize(lb, {detailed: true, vms_serialized: !api?})
        if api?
          @lb
        else
          vms = dataset_authorize(lb.private_subnet.vms_dataset, "Vm:view").exclude(Sequel[:vm][:id] => lb.vms_dataset.select(Sequel[:vm][:id])).all
          @attachable_vms = Serializers::Vm.serialize(vms)

          view "networking/load_balancer/show"
        end
      end

      r.delete true do
        authorize("LoadBalancer:delete", lb.id)
        lb.incr_destroy
        response.status = 204
        r.halt
      end

      r.patch api? do
        authorize("LoadBalancer:edit", lb.id)
        request_body_params = Validation.validate_request_body(json_params, %w[algorithm src_port dst_port health_check_endpoint vms])
        lb.update(
          algorithm: request_body_params["algorithm"],
          src_port: Validation.validate_port(:src_port, request_body_params["src_port"]),
          dst_port: Validation.validate_port(:dst_port, request_body_params["dst_port"]),
          health_check_endpoint: request_body_params["health_check_endpoint"]
        )

        new_vms = request_body_params["vms"].map { Vm.from_ubid(_1.delete("\"")) }
        new_vms.each do |vm|
          unless vm
            fail Validation::ValidationFailed.new("vms" => "VM not found")
          end

          authorize("Vm:view", vm.id)
          if vm.load_balancer
            next if vm.load_balancer.id == lb.id
            fail Validation::ValidationFailed.new("vms" => "VM is already attached to a load balancer")
          end
          lb.add_vm(vm)
        end

        lb.vms.each do |vm|
          next if new_vms.any? { _1.id == vm.id }
          lb.evacuate_vm(vm)
          lb.remove_vm(vm)
        end

        lb.incr_update_load_balancer
        Serializers::LoadBalancer.serialize(lb.reload, {detailed: true})
      end
    end

    # 204 response for invalid names
    r.is String do |lb_name|
      r.post { load_balancer_post(lb_name) }

      r.delete do
        response.status = 204
        nil
      end
    end
  end
end
