# frozen_string_literal: true

class Clover
  def authorized_vm(perm: "Vm:view", location_id: nil)
    authorized_object(association: :vms, key: "vm_id", perm:, location_id:)
  end

  def vm_list_dataset
    dataset_authorize(@project.vms_dataset, "Vm:view")
  end

  def vm_list_api_response(dataset)
    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset, Serializers::Vm)
  end

  def vm_post(name)
    project = @project
    authorize("Vm:create", project.id)
    fail Validation::ValidationFailed.new({billing_info: "Project doesn't have valid billing information"}) unless project.has_valid_payment_method?

    public_key = typecast_params.nonempty_str!("public_key")
    assemble_params = typecast_params.convert!(symbolize: true) do |tp|
      tp.nonempty_str(["size", "unix_user", "boot_image", "private_subnet_id", "gpu"])
      tp.pos_int("storage_size")
      tp.bool("enable_ip4")
    end
    assemble_params.compact!

    # Generally parameter validation is handled in progs while creating resources.
    # Since Vm::Nexus both handles VM creation requests from user and also Postgres
    # service, moved the boot_image validation here to not allow users to pass
    # postgres image as boot image while creating a VM.
    if assemble_params[:boot_image]
      Validation.validate_boot_image(assemble_params[:boot_image])
    end

    # Same as above, moved the size validation here to not allow users to
    # pass gpu instance while creating a VM.
    if assemble_params[:size]
      parsed_size = Validation.validate_vm_size(assemble_params[:size], "x64", only_visible: true)
    end

    if assemble_params[:storage_size]
      storage_size = Validation.validate_vm_storage_size(assemble_params[:size] || Prog::Vm::Nexus::DEFAULT_SIZE, "x64", assemble_params[:storage_size])
      assemble_params[:storage_volumes] = [{size_gib: storage_size, encrypted: true}]
      assemble_params.delete(:storage_size)
    end

    if assemble_params[:gpu]
      gpu_count, gpu_device = Validation.validate_vm_gpu(assemble_params[:gpu], @location.name, project, parsed_size)
      assemble_params[:gpu_count] = gpu_count
      assemble_params[:gpu_device] = gpu_device
      assemble_params.delete(:gpu)
    end

    if assemble_params[:private_subnet_id]
      unless (ps = authorized_private_subnet(location_id: @location.id))
        fail Validation::ValidationFailed.new({private_subnet_id: "Private subnet with the given id \"#{assemble_params[:private_subnet_id]}\" is not found in the location \"#{@location.display_name}\""})
      end
    end
    assemble_params[:private_subnet_id] = ps&.id

    requested_vm_vcpu_count = parsed_size.nil? ? 2 : parsed_size.vcpus
    Validation.validate_vcpu_quota(project, "VmVCpu", requested_vm_vcpu_count)

    vm = nil
    DB.transaction do
      vm = Prog::Vm::Nexus.assemble(
        public_key,
        project.id,
        name:,
        location_id: @location.id,
        **assemble_params
      ).subject
      audit_log(vm, "create")
    end

    if api?
      Serializers::Vm.serialize(vm, {detailed: true})
    else
      flash["notice"] = "'#{name}' will be ready in a few minutes"
      request.redirect "#{project.path}#{vm.path}"
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
    options.add_option(name: "private_subnet_id", values: subnets, parent: "location", check: ->(location, private_subnet) {
      private_subnet[:location_id] == location.id
    })

    options.add_option(name: "enable_ip4", values: ["1"], parent: "location")
    options.add_option(name: "family", values: Option.families.map(&:name), parent: "location", check: ->(location, family) {
      !!BillingRate.from_resource_properties("VmVCpu", family, location.name)
    })
    options.add_option(name: "size", values: Option::VmSizes.select { it.visible }.map { it.display_name }, parent: "family", check: ->(location, family, size) {
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      vm_size.family == family
    })

    options.add_option(name: "storage_size", values: ["10", "20", "40", "80", "160", "320", "600", "640", "1200", "2400"], parent: "size", check: ->(location, family, size, storage_size) {
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      vm_size.storage_size_options.include?(storage_size.to_i)
    })

    available_gpus = DB.from(DB[:pci_device].join(:vm_host, id: :vm_host_id).join(:location, id: :location_id).where(device_class: ["0300", "0302"], vm_id: nil).group_and_count(:vm_host_id, :name, :device))
      .select { [name.as(location_name), device, max(:count).as(:max_count)] }.group(:name, :device)

    gpu_counts = [1, 2, 4, 8]
    gpu_options = available_gpus.map { it[:device] }.uniq.flat_map { |x| gpu_counts.map { |i| "#{i}:#{x}" } }
    gpu_availability = available_gpus.each_with_object({}) do |entry, hash|
      hash[entry[:location_name]] ||= {}
      hash[entry[:location_name]][entry[:device]] = entry[:max_count]
    end

    options.add_option(name: "gpu", values: ["0:"] + gpu_options, parent: "family", check: ->(location, family, gpu) {
      gpu = gpu.split(":")
      gpu_count = gpu[0].to_i
      gpu_count == 0 || (family == "standard" && !!BillingRate.from_resource_properties("Gpu", gpu[1], location.name) && gpu_availability[location.name] && gpu_availability[location.name][gpu[1]] && gpu_availability[location.name][gpu[1]] >= gpu_count)
    })

    options.add_option(name: "boot_image", values: Option::BootImages.map(&:name))
    options.add_option(name: "unix_user")
    options.add_option(name: "public_key")

    options.serialize
  end
end
