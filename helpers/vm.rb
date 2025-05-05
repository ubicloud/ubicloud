# frozen_string_literal: true

class Clover
  def vm_list_dataset
    dataset_authorize(@project.vms_dataset, "Vm:view")
  end

  def vm_list_api_response(dataset)
    dataset = dataset.where(location_id: @location.id) if @location
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

    allowed_optional_parameters = ["size", "storage_size", "unix_user", "boot_image", "enable_ip4", "private_subnet_id"]
    request_body_params = validate_request_params(%w[public_key name location])
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
      parsed_size = Validation.validate_vm_size(assemble_params["size"], "x64", only_visible: true)
    end

    if assemble_params["storage_size"]
      storage_size = Validation.validate_vm_storage_size(assemble_params["size"] || Prog::Vm::Nexus::DEFAULT_SIZE, "x64", assemble_params["storage_size"])
      assemble_params["storage_volumes"] = [{size_gib: storage_size, encrypted: true}]
      assemble_params.delete("storage_size")
    end

    if assemble_params["private_subnet_id"] && assemble_params["private_subnet_id"] != ""
      ps = PrivateSubnet.from_ubid(assemble_params["private_subnet_id"])
      if !ps || ps.location_id != @location.id
        fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{assemble_params["private_subnet_id"]}\" is not found in the location \"#{@location.display_name}\""})
      end
      authorize("PrivateSubnet:view", ps.id)
    end
    assemble_params["private_subnet_id"] = ps&.id

    requested_vm_vcpu_count = parsed_size.nil? ? 2 : parsed_size.vcpus
    Validation.validate_vcpu_quota(project, "VmVCpu", requested_vm_vcpu_count)

    st = Prog::Vm::Nexus.assemble(
      request_body_params["public_key"],
      project.id,
      name: name,
      location_id: @location.id,
      **assemble_params.transform_keys(&:to_sym)
    )
    if api?
      Serializers::Vm.serialize(st.subject, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect "#{project.path}#{st.subject.path}"
    end
  end

  def generate_vm_options
    options = OptionTreeGenerator.new

    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.locations(feature_flags: @project.feature_flags))

    subnets = dataset_authorize(@project.private_subnets_dataset, "PrivateSubnet:view").map {
      {
        location_id: it.location_id,
        value: it.ubid,
        display_name: it.name
      }
    }
    options.add_option(name: "private_subnet_id", values: subnets, parent: "location") do |location, private_subnet|
      private_subnet[:location_id] == location.id
    end

    options.add_option(name: "enable_ip4", values: ["1"], parent: "location")
    options.add_option(name: "family", values: Option.families.map(&:name), parent: "location") do |location, family|
      !!BillingRate.from_resource_properties("VmVCpu", family, location.name)
    end
    options.add_option(name: "size", values: Option::VmSizes.select { it.visible }.map { it.display_name }, parent: "family") do |location, family, size|
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      vm_size.family == family
    end

    options.add_option(name: "storage_size", values: ["10", "20", "40", "80", "160", "320", "600", "640", "1200", "2400"], parent: "size") do |location, family, size, storage_size|
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      vm_size.storage_size_options.include?(storage_size.to_i)
    end

    options.add_option(name: "boot_image", values: Option::BootImages.map(&:name))
    options.add_option(name: "unix_user")
    options.add_option(name: "public_key")

    options.serialize
  end
end
