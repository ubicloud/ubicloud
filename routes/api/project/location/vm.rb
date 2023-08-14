# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Api::Vm

    r.get true do
      vms = @project.vms_dataset.where(location: @location).authorized(@current_user.id, "Vm:view").eager(:semaphores).all

      serialize(vms)
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Vm:create", @project.id)
      fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

      st = Prog::Vm::Nexus.assemble(
        r.params["public_key"],
        @project.id,
        name: r.params["name"],
        unix_user: r.params["unix_user"],
        size: r.params["size"],
        location: @location,
        boot_image: r.params["boot_image"]
      )

      serialize(st.vm)
    end

    r.is String do |vm_name|
      vm = @project.vms_dataset.where(location: @location).where { {Sequel[:vm][:name] => vm_name} }.first

      unless vm
        response.status = 404
        r.halt
      end

      r.get true do
        Authorization.authorize(@current_user.id, "Vm:view", vm.id)

        serialize(vm)
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Vm:delete", vm.id)

        vm.incr_destroy

        serialize(vm)
      end
    end
  end
end
