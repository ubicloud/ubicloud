# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "vm") do |r|
    r.get api? do
      vm_list_api_response(vm_list_dataset)
    end

    r.on VM_NAME_OR_UBID do |vm_name, vm_id|
      if vm_name
        r.post api? do
          check_visible_location
          vm_post(vm_name)
        end

        filter = {Sequel[:vm][:name] => vm_name}
      else
        filter = {Sequel[:vm][:id] => vm_id}
      end

      filter[:location_id] = @location.id
      vm = @vm = @project.vms_dataset.first(filter)
      check_found_object(vm)

      r.get true do
        authorize("Vm:view", vm)

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          r.redirect vm, "/overview"
        end
      end

      r.delete true do
        authorize("Vm:delete", vm)

        DB.transaction do
          vm.incr_destroy
          audit_log(vm, "destroy")
        end

        if web?
          flash["notice"] = "Virtual machine scheduled for deletion."
          r.redirect @project, "/vm"
        else
          204
        end
      end

      r.rename vm, perm: "Vm:edit", serializer: Serializers::Vm, template_prefix: "vm"

      r.show_object(vm, actions: %w[overview networking settings], perm: "Vm:view", template: "vm/show")

      r.post %w[restart start stop] do |action|
        authorize("Vm:edit", vm)
        handle_validation_failure("vm/show") { @page = "settings" }

        if vm.aws?
          raise CloverError.new(400, "InvalidRequest", "The #{action} action is not supported for VMs running on AWS")
        end

        unless vm.send(:"can_#{action}?")
          raise CloverError.new(400, "InvalidRequest", "The #{action} action is not supported in the VM's current state")
        end

        DB.transaction do
          vm.public_send(:"incr_#{action}")
          audit_log(vm, action)
        end

        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          notice = "Scheduled #{action} of #{vm.name}"
          if action == "stop"
            notice << ". Note that stopped VMs still accrue billing charges. To stop billing charges, delete the VM."
          end
          flash["notice"] = notice
          r.redirect vm, "/settings"
        end
      end
    end
  end
end
