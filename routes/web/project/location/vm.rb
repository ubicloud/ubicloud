# frozen_string_literal: true

class CloverWeb
  CloverBase.run_on_location :get_vm do |project, name|
    project.vms_dataset.where { {Sequel[:vm][:name] => name} }.first
  end

  CloverBase.run_on_location :delete_vm do |vm|
    vm.incr_destroy
  end

  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Web::Vm

    r.is String do |vm_name|
      vm = get_vm(@location, @project, vm_name)

      unless vm
        response.status = 404
        r.halt
      end

      r.get true do
        Authorization.authorize(@current_user.id, "Vm:view", vm.id)

        @vm = serialize(vm, :detailed)

        view "vm/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Vm:delete", vm.id)

        delete_vm(@location, vm)

        return {message: "Deleting #{vm.name}"}.to_json
      end
    end
  end
end
