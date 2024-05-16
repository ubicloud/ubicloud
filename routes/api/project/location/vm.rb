# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "vm") do |r|
    @serializer = Serializers::Api::Vm

    r.get true do
      result = @project.vms_dataset.where(location: @location).authorized(@current_user.id, "Vm:view").paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: serialize(result[:records]),
        count: result[:count]
      }
    end

    r.on "id" do
      r.on String do |vm_ubid|
        vm = Vm.from_ubid(vm_ubid)
        handle_vm_requests(@current_user, vm)
      end
    end

    r.on String do |vm_name|
      r.post true do
        Authorization.authorize(@current_user.id, "Vm:create", @project.id)
        fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless @project.has_valid_payment_method?

        required_parameters = ["public_key"]
        allowed_optional_parameters = ["size", "unix_user", "boot_image", "enable_ip4", "private_subnet_id"]

        request_body_params = Validation.validate_request_body(r.body.read, required_parameters, allowed_optional_parameters)

        # Generally parameter validation is handled in progs while creating resources.
        # Since Vm::Nexus both handles VM creation requests from user and also Postgres
        # service, moved the boot_image validation here to not allow users to pass
        # postgres image as boot image while creating a VM.
        if request_body_params["boot_image"]
          Validation.validate_boot_image(request_body_params["boot_image"])
        end

        # Same as above, moved the size validation here to not allow users to
        # pass gpu instance while creating a VM.
        if request_body_params["size"]
          Validation.validate_vm_size(request_body_params["size"], only_visible: true)
        end

        if request_body_params["private_subnet_id"]
          ps = PrivateSubnet.from_ubid(request_body_params["private_subnet_id"])
          unless ps && ps.location == @location
            fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{request_body_params["private_subnet_id"]}\" is not found in the location \"#{LocationNameConverter.to_display_name(@location)}\""})
          end
          Authorization.authorize(@current_user.id, "PrivateSubnet:view", ps.id)
          request_body_params["private_subnet_id"] = ps.id
        end

        st = Prog::Vm::Nexus.assemble(
          request_body_params["public_key"],
          @project.id,
          name: vm_name,
          location: @location,
          **request_body_params.except(*required_parameters).transform_keys(&:to_sym)
        )

        serialize(st.subject, :detailed)
      end

      vm = @project.vms_dataset.where(location: @location).where { {Sequel[:vm][:name] => vm_name} }.first
      handle_vm_requests(@current_user, vm)
    end
  end

  def handle_vm_requests(user, vm)
    unless vm
      response.status = request.delete? ? 204 : 404
      request.halt
    end

    request.get true do
      Authorization.authorize(user.id, "Vm:view", vm.id)
      serialize(vm, :detailed)
    end

    request.delete true do
      Authorization.authorize(user.id, "Vm:delete", vm.id)
      vm.incr_destroy

      response.status = 204
      request.halt
    end
  end
end
