# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    vm_endpoint_helper = Routes::Common::VmHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil)

    r.get api? do
      vm_endpoint_helper.list
    end

    r.on NAME_OR_UBID do |vm_name, vm_ubid|
      if vm_name
        r.post api? do
          vm_endpoint_helper.post(vm_name)
        end

        filter = {Sequel[:vm][:name] => vm_name}
      else
        filter = {Sequel[:vm][:id] => UBID.to_uuid(vm_ubid)}
      end

      filter[:location] = @location
      vm = @project.vms_dataset.first(filter)

      unless vm
        response.status = request.delete? ? 204 : 404
        request.halt
      end

      vm_endpoint_helper.instance_variable_set(:@resource, vm)

      r.get true do
        vm_endpoint_helper.get
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
        vm_endpoint_helper.post(vm_name)
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
