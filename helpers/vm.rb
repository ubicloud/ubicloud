# frozen_string_literal: true

class Clover
  def vm_list_dataset
    dataset_authorize(@project.vms_dataset, "Vm:view")
  end

  def vm_list_api_response(dataset)
    dataset = dataset.where(location: @location) if @location
    result = dataset.paginated_result(
      start_after: request.params["start_after"],
      page_size: request.params["page_size"],
      order_column: request.params["order_column"]
    )

    {
      items: Serializers::Vm.serialize(result[:records]),
      count: result[:count]
    }
  end

  def vm_post(name)
    project = @project
    authorize("Vm:create", project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless project.has_valid_payment_method?

    required_parameters = ["public_key"]
    required_parameters << "name" << "location" if web?
    allowed_optional_parameters = ["size", "storage_size", "unix_user", "boot_image", "enable_ip4", "private_subnet_id"]
    request_body_params = validate_request_params(required_parameters, allowed_optional_parameters)
    assemble_params = request_body_params.slice(*allowed_optional_parameters).compact

    # Generally parameter validation is handled in progs while creating resources.
    # Since Vm::Nexus both handles VM creation requests from user and also Postgres
    # service, moved the boot_image validation here to not allow users to pass
    # postgres image as boot image while creating a VM.
    if assemble_params["boot_image"]
      Validation.validate_boot_image(assemble_params["boot_image"])
    end

    # Same as above, moved the size validation here to not allow users to
    # pass gpu instance while creating a VM.
    if assemble_params["size"]
      parsed_size = Validation.validate_vm_size(assemble_params["size"], only_visible: true)
    end

    if assemble_params["storage_size"]
      storage_size = Validation.validate_vm_storage_size(assemble_params["size"], assemble_params["storage_size"])
      assemble_params["storage_volumes"] = [{size_gib: storage_size, encrypted: true}]
      assemble_params.delete("storage_size")
    end

    if assemble_params["private_subnet_id"] && assemble_params["private_subnet_id"] != ""
      ps = PrivateSubnet.from_ubid(assemble_params["private_subnet_id"])
      if !ps || ps.location != @location
        fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{assemble_params["private_subnet_id"]}\" is not found in the location \"#{LocationNameConverter.to_display_name(@location)}\""})
      end
      authorize("PrivateSubnet:view", ps.id)
    end
    assemble_params["private_subnet_id"] = ps&.id

    requested_vm_core_count = parsed_size.nil? ? 1 : parsed_size.vcpu / 2
    Validation.validate_core_quota(project, "VmCores", requested_vm_core_count)

    st = Prog::Vm::Nexus.assemble(
      request_body_params["public_key"],
      project.id,
      name: name,
      location: @location,
      **assemble_params.transform_keys(&:to_sym)
    )

    if api?
      Serializers::Vm.serialize(st.subject, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect "#{project.path}#{st.subject.path}"
    end
  end
end
