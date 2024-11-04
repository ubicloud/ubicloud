# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.get api? do
      vm_list_api_response(vm_list_dataset)
    end

    r.on NAME_OR_UBID do |vm_name, vm_ubid|
      if vm_name
        r.post api? do
          vm_post(vm_name)
        end

        filter = {Sequel[:vm][:name] => vm_name}
      else
        filter = {Sequel[:vm][:id] => UBID.to_uuid(vm_ubid)}
      end

      filter[:location] = @location
      vm = @project.vms_dataset.first(filter)

      unless vm
        response.status = r.delete? ? 204 : 404
        r.halt
      end

      r.get true do
        Authorization.authorize(current_account.id, "Vm:view", vm.id)
        @vm = Serializers::Vm.serialize(vm, {detailed: true})
        api? ? @vm : view("vm/show")
      end

      r.delete true do
        Authorization.authorize(current_account.id, "Vm:delete", vm.id)
        vm.incr_destroy
        response.status = 204
        nil
      end
    end

    # 204 response for invalid names
    r.is String do |vm_name|
      r.post do
        vm_post(vm_name)
      end

      r.delete do
        response.status = 204
        nil
      end
    end
  end

  hash_branch(:api_project_location_prefix, "vm", &branch)
  hash_branch(:project_location_prefix, "vm", &branch)
end
