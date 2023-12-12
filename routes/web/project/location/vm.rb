# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Web::Vm

    r.is String do |vm_name|
      vm = ResourceManager.get(@location, @project, vm_name, "vm")

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

        # TODOBV: Have semaphore funcs on accessor
        ResourceManager.delete(@location, vm, "vm")

        return {message: "Deleting #{vm.name}"}.to_json
      end
    end
  end
end
