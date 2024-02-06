# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Api::Vm

    r.get true do
      result = @project.vms_dataset.where(location: @location).authorized(@current_user.id, "Vm:view").eager(:semaphores).paginated_result(
        r.params["cursor"],
        r.params["page-size"],
        r.params["order-column"]
      )

      {
        values: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.is String do |vm_name|
      r.post true do
        Authorization.authorize(@current_user.id, "Vm:create", @project.id)
        fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

        required_parameters = ["public_key"]
        allowed_optional_parameters = ["size", "unix_user", "location", "boot_image"]

        request_body = r.body.read
        Validation.validate_request_body(request_body, required_parameters, allowed_optional_parameters)

        request_body_params = JSON.parse(request_body)

        st = Prog::Vm::Nexus.assemble(
          request_body_params["public_key"],
          @project.id,
          name: vm_name,
          **request_body_params.except(*required_parameters).transform_keys { |key| key.to_sym }
        )

        serialize(st.subject)
      end

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
