# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "vm") do |r|
    vm_endpoint_helper = Routes::Common::VmHelper.new(app: self, request: r, user: @current_user, location: @location, resource: nil)

    r.get true do
      vm_endpoint_helper.list
    end

    r.on "id" do
      r.on String do |vm_ubid|
        vm = Vm.from_ubid(vm_ubid)

        if vm&.location != @location
          vm = nil
        end

        vm_endpoint_helper.instance_variable_set(:@resource, vm)
        handle_vm_requests(vm_endpoint_helper)
      end
    end

    r.on String do |vm_name|
      r.post true do
        vm_endpoint_helper.post(vm_name)
      end

      vm_endpoint_helper.instance_variable_set(:@resource, @project.vms_dataset.where(location: @location).where { {Sequel[:vm][:name] => vm_name} }.first)
      handle_vm_requests(vm_endpoint_helper)
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
