# frozen_string_literal: true

class Clover
  def machine_image_list_dataset
    dataset_authorize(@project.machine_images_dataset, "MachineImage:view")
  end

  def machine_image_list_api_response(dataset)
    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset.eager(:location, versions: :vm).order(Sequel.desc(:created_at)), Serializers::MachineImage)
  end

  def machine_image_post(name = nil)
    authorize("MachineImage:create", @project)

    name ||= typecast_params.nonempty_str!("name")
    Validation.validate_name(name)
    description = typecast_params.str("description") || ""

    vm_ubid = typecast_params.str!("vm_id")
    vm = dataset_authorize(@project.vms_dataset, "Vm:view").first(id: UBID.to_uuid(vm_ubid))
    unless vm
      fail Validation::ValidationFailed.new({vm_id: "VM with the given id \"#{vm_ubid}\" is not found"})
    end

    unless vm.display_state == "stopped"
      fail Validation::ValidationFailed.new({vm_id: "VM must be in 'stopped' state to create a machine image. Current state: '#{vm.display_state}'. Please stop the VM and try again."})
    end

    boot_vol = vm.vm_storage_volumes.find(&:boot)
    unless boot_vol&.vhost_block_backend_id
      fail Validation::ValidationFailed.new({vm_id: "This VM was created before write tracking was enabled and cannot be imaged. Please create a new VM, transfer your data, and try again."})
    end

    if @location && vm.location_id != @location.id
      fail Validation::ValidationFailed.new({vm_id: "VM must be in the same location as the machine image"})
    end

    boot_size_gib = boot_vol.size_gib
    max_size_gib = Config.machine_image_max_size_gib
    if boot_size_gib > max_size_gib
      fail Validation::ValidationFailed.new({vm_id: "VM boot disk size (#{boot_size_gib} GiB) exceeds maximum image size (#{max_size_gib} GiB)"})
    end

    if MachineImageVersion.where(vm_id: vm.id).exclude(state: ["available", "failed", "destroying"]).any?
      fail Validation::ValidationFailed.new({vm_id: "A machine image is already being created from this VM"})
    end

    Validation.validate_machine_image_quota(@project, image_size_gib: boot_size_gib)

    location = vm.location

    machine_image = nil
    version = nil
    DB.transaction do
      # Find or create the parent MachineImage
      machine_image = MachineImage.where(project_id: @project.id, location_id: location.id, name:).first
      if machine_image
        machine_image.update(description:) unless description.empty?
      else
        machine_image = MachineImage.create(
          name:,
          description:,
          location_id: location.id,
          project_id: @project.id,
          arch: vm.arch
        )
      end

      # Auto-increment version number
      max_version = MachineImageVersion.where(machine_image_id: machine_image.id).max(:version) || 0

      version = MachineImageVersion.create(
        machine_image_id: machine_image.id,
        version: max_version + 1,
        state: "creating",
        vm_id: vm.id,
        size_gib: boot_size_gib,
        s3_bucket: Config.machine_image_archive_bucket || "",
        s3_prefix: "#{@project.ubid}/#{location.display_name}/",
        s3_endpoint: Config.machine_image_archive_endpoint || ""
      )
      version.update(s3_prefix: "#{version.s3_prefix}#{version.ubid}/")
      Strand.create(id: version.id, prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => version.id}])
      audit_log(machine_image, "create")
    end

    if api?
      Serializers::MachineImage.serialize(machine_image.refresh)
    else
      flash["notice"] = "'#{name}' is being created"
      request.redirect machine_image
    end
  end

  def generate_machine_image_options
    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "description")
    options.add_option(name: "location", values: Option.locations)
    stopped_vms = dataset_authorize(@project.vms_dataset, "Vm:view")
      .eager(:vm_storage_volumes, :location)
      .all
      .select { it.display_state == "stopped" }
      .map {
        {
          location_id: it.location_id,
          value: it.ubid,
          display_name: it.name
        }
      }
    options.add_option(name: "vm_id", values: stopped_vms, parent: "location") do |location, vm|
      vm[:location_id] == location.id
    end
    options.serialize
  end
end
