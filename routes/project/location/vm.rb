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
      vm = @project.vms_dataset.eager(:location).first(filter)

      next(r.delete? ? 204 : 404) unless vm

      r.get true do
        authorize("Vm:view", vm.id)
        @vm = Serializers::Vm.serialize(vm, {detailed: true, include_path: web?})
        api? ? @vm : view("vm/show")
      end

      r.delete true do
        authorize("Vm:delete", vm.id)
        vm.incr_destroy
        204
      end

      r.post "restart" do
        authorize("Vm:edit", vm.id)
        vm.incr_restart
        if api?
          Serializers::Vm.serialize(vm, {detailed: true})
        else
          flash["notice"] = "'#{vm.name}' will be restarted in a few seconds"
          r.redirect "#{@project.path}#{vm.path}"
        end
      end
    end
  end
end
