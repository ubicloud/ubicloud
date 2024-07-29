# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "vm") do |r|
    r.on String do |vm_name|
      vm = @project.vms_dataset.where(location: @location).where { {Sequel[:vm][:name] => vm_name} }.first

      unless vm
        response.status = 404
        r.halt
      end

      vm_endpoint_helper = Routes::Common::VmHelper.new(app: self, request: r, user: @current_user, location: @location, resource: vm)

      r.get true do
        vm_endpoint_helper.get
      end

      r.delete true do
        vm_endpoint_helper.delete
      end
    end
  end
end
