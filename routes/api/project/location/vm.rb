# frozen_string_literal: true

class CloverApi
  hash_branch(:api_project_location_prefix, "vm") do |r|
    vm_endpoint_helper = Routes::Common::VmHelper.new(app: self, request: r, user: current_account, location: @location, resource: nil)

    r.get true do
      vm_endpoint_helper.list
    end

    r.on NAME_OR_UBID do |vm_name, vm_ubid|
      if vm_name
        r.post true do
          vm_endpoint_helper.post(vm_name)
        end

        filter = {Sequel[:vm][:name] => vm_name}
      else
        filter = {Sequel[:vm][:id] => UBID.to_uuid(vm_ubid)}
      end

      filter[:location] = @location
      vm = @project.vms_dataset.first(filter)
      vm_endpoint_helper.instance_variable_set(:@resource, vm)
      handle_vm_requests(vm_endpoint_helper)
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

  def handle_vm_requests(vm_endpoint_helper)
    unless vm_endpoint_helper.instance_variable_get(:@resource)
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.get true do
      vm_endpoint_helper.get
    end

    request.delete true do
      vm_endpoint_helper.delete
    end
  end
end
