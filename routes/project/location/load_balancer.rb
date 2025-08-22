# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "load-balancer") do |r|
    r.get api? do
      load_balancer_list
    end

    r.on LOAD_BALANCER_NAME_OR_UBID do |lb_name, lb_id|
      if lb_name
        r.post api? do
          check_visible_location
          load_balancer_post(lb_name)
        end

        filter = {Sequel[:load_balancer][:name] => lb_name}
      else
        filter = {Sequel[:load_balancer][:id] => UBID.to_uuid(lb_id)}
      end

      filter[:private_subnet_id] = @project.private_subnets_dataset.where(location_id: @location.id).select(Sequel[:private_subnet][:id])
      @lb = lb = LoadBalancer.first(filter)

      check_found_object(lb)

      r.post %w[attach-vm detach-vm] do |action|
        authorize("LoadBalancer:edit", lb.id)
        handle_validation_failure("networking/load_balancer/show")

        unless (vm = authorized_vm(location_id: lb.private_subnet.location_id))
          fail Validation::ValidationFailed.new("vm_id" => "No matching VM found in #{lb.display_location}")
        end

        actioned = nil

        DB.transaction do
          if action == "attach-vm"
            if vm.load_balancer
              fail Validation::ValidationFailed.new("vm_id" => "VM is already attached to a load balancer")
            end
            lb.add_vm(vm)
            audit_log(lb, "attach_vm", vm)
            actioned = "attached to"
          else
            lb.detach_vm(vm)
            audit_log(lb, "detach_vm", vm)
            actioned = "detached from"
          end
        end

        if api?
          Serializers::LoadBalancer.serialize(lb, {detailed: true})
        else
          flash["notice"] = "VM is #{actioned} the load balancer"
          r.redirect path(lb)
        end
      end

      r.is do
        r.get do
          authorize("LoadBalancer:view", lb.id)
          if api?
            Serializers::LoadBalancer.serialize(lb, {detailed: true})
          else
            view "networking/load_balancer/show"
          end
        end

        r.delete do
          authorize("LoadBalancer:delete", lb.id)
          DB.transaction do
            lb.incr_destroy
            audit_log(lb, "destroy")
          end
          204
        end

        r.patch api? do
          authorize("LoadBalancer:edit", lb.id)
          algorithm, health_check_endpoint = typecast_params.nonempty_str!(%w[algorithm health_check_endpoint])
          src_port, dst_port = typecast_params.pos_int!(%w[src_port dst_port])
          vm_ids = typecast_params.array(:ubid_uuid, "vms")

          DB.transaction do
            lb.update(algorithm:, health_check_endpoint:)
            lb.ports.first.update(src_port: Validation.validate_port(:src_port, src_port),
              dst_port: Validation.validate_port(:dst_port, dst_port))

            new_vms = dataset_authorize(@project.vms_dataset, "Vm:view").eager(:load_balancer).where(id: vm_ids).all

            unless vm_ids.length == new_vms.length
              fail Validation::ValidationFailed.new("vms" => "VM not found")
            end

            new_vms.each do |vm|
              if (lb_id = vm.load_balancer&.id)
                next if lb_id == lb.id
                fail Validation::ValidationFailed.new("vms" => "VM is already attached to a load balancer")
              end
              lb.add_vm(vm)
            end

            lb.vms.each do |vm|
              next if new_vms.any? { it.id == vm.id }
              lb.evacuate_vm(vm)
              lb.remove_vm(vm)
            end

            lb.incr_update_load_balancer
            audit_log(lb, "update")
          end
          Serializers::LoadBalancer.serialize(lb.reload, {detailed: true})
        end
      end

      r.rename lb, perm: "LoadBalancer:edit", serializer: Serializers::LoadBalancer
    end
  end
end
