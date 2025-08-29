# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "vm") do |r|
    r.get api? do
      vm_list_api_response(vm_list_dataset)
    end

    r.on VM_NAME_OR_UBID do |vm_name, vm_ubid|
      if vm_name
        r.post api? do
          check_visible_location
          vm_post(vm_name)
        end

        filter = {Sequel[:vm][:name] => vm_name}
      else
        filter = {Sequel[:vm][:id] => UBID.to_uuid(vm_ubid)}
      end

      filter[:location_id] = @location.id
      vm = @vm = @project.vms_dataset.first(filter)
      check_found_object(vm)

      r.get true do
        authorize("Vm:view", vm.id)

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          r.redirect vm, "/overview"
        end
      end

      r.delete true do
        authorize("Vm:delete", vm.id)

        DB.transaction do
          vm.incr_destroy
          audit_log(vm, "destroy")
        end

        204
      end

      r.rename vm, perm: "Vm:edit", serializer: Serializers::Vm, template_prefix: "vm"
      r.show_object(vm, actions: %w[overview networking settings], perm: "Vm:view", template: "vm/show")

      r.post "restart" do
        authorize("Vm:edit", vm.id)

        DB.transaction do
          vm.incr_restart
          audit_log(vm, "restart")
        end

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          flash["notice"] = "'#{vm.name}' will be restarted in a few seconds"
          r.redirect vm, "/settings"
        end
      end
    end
  end
end
