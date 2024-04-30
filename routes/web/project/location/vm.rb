# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Web::Vm

    r.on String do |vm_name|
      vm = @project.vms_dataset.where(location: @location).where { {Sequel[:vm][:name] => vm_name} }.first

      unless vm
        response.status = 404
        r.halt
      end

      r.get true do
        Authorization.authorize(@current_user.id, "Vm:view", vm.id)

        @vm = serialize(vm)

        view "vm/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Vm:delete", vm.id)

        vm.incr_destroy

        return {message: "Deleting #{vm.name}"}.to_json
      end
    end
  end
end
