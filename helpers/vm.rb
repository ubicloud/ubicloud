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
    authorize("Vm:create", project)
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
      request.redirect vm
    end
  end

  def generate_vm_options
    options = OptionTreeGenerator.new

    @show_gpu = typecast_params.bool("show_gpu")
    @show_gpu = false unless @project.get_ff_gpu_vm
    # @show_gpu:
    # true: Only show options valid for GPU configurations
    # false: Do not show GPU options
    # nil: Show GPU options, but also show options not valid for GPU configurations

    if @show_gpu != false
      available_gpus = DB[:pci_device]
        .join(:vm_host, id: :vm_host_id)
        .join(:location, id: :location_id)
        .where(device_class: ["0300", "0302"], vm_id: nil, visible: true)
        .group_and_count(:vm_host_id, :name, :device)
        .from_self
        .select_group { [name.as(:location_name), device] }
        .select_append { max(:count).as(:max_count) }
        .all.filter { !!BillingRate.from_resource_properties("Gpu", it[:device], it[:location_name]) }

      gpu_counts = [1, 2, 4, 8]
      gpu_options = available_gpus.map { it[:device] }.uniq.flat_map { |x| gpu_counts.map { |i| "#{i}:#{x}" } }
      gpu_availability = available_gpus.each_with_object({}) do |entry, hash|
        hash[entry[:location_name]] ||= {}
        hash[entry[:location_name]][entry[:device]] = entry[:max_count]
      end
      gpu_locations = gpu_availability.keys

      if @show_gpu
        if gpu_locations.empty? && web?
          flash["error"] = "Unfortunately, no virtual machines with GPUs are currently available."
          request.redirect @project, "/vm/create"
        end

        location_family_check = lambda do |location, family|
          !gpu_locations.include?(location.name) || family == "burstable"
        end
      end
    end

    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.locations(feature_flags: @project.feature_flags)) do |location|
      !@show_gpu || gpu_locations.include?(location.name)
    end

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
      next false if location_family_check&.call(location, family)
      !!BillingRate.from_resource_properties("VmVCpu", family, location.name)
    end

    options.add_option(name: "size", values: Option::VmSizes.select(&:visible).map(&:display_name), parent: "family") do |location, family, size|
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      vm_size.family == family
    end

    options.add_option(name: "storage_size", values: ["10", "20", "40", "80", "160", "320", "600", "640", "1200", "2400"], parent: "size") do |location, family, size, storage_size|
      vm_size = Option::VmSizes.find { it.display_name == size && it.arch == "x64" }
      vm_size.storage_size_options.include?(storage_size.to_i)
    end

    if @show_gpu != false
      base_gpu_options = @show_gpu ? [] : ["0:"]
      options.add_option(name: "gpu", values: base_gpu_options + gpu_options, parent: "family") do |location, family, gpu|
        gpu_count, device = gpu.split(":", 2)
        gpu_count = gpu_count.to_i
        device_availability = gpu_availability.dig(location.name, device)
        next true if gpu_count == 0

        family == "standard" &&
          !!BillingRate.from_resource_properties("Gpu", device, location.name) &&
          device_availability &&
          device_availability >= gpu_count
      end
    end

    options.add_option(name: "boot_image", values: Option::BootImages.map(&:name))
    options.add_option(name: "unix_user")
    options.add_option(name: "public_key")

    options.serialize
  end
end
