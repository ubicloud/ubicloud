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
    vm_id = typecast_params.nonempty_str("vm_id")
    version_str = typecast_params.nonempty_str("version")

    unless @location
      fail Validation::ValidationFailed.new({location: "Location is required"})
    end

    machine_image = nil
    version = nil
    DB.transaction do
      machine_image = MachineImage.create(
        name:,
        description:,
        location_id: @location.id,
        project_id: @project.id,
        arch: "x64"
      )
      if vm_id
        version = create_version_from_vm(machine_image, vm_id, version_str)
        machine_image.update(arch: version.vm.arch)
      end
      audit_log(machine_image, "create")
    end

    if api?
      Serializers::MachineImage.serialize(machine_image.refresh)
    else
      notice = version ? "'#{name}' is being created" : "'#{name}' has been created"
      flash["notice"] = notice
      request.redirect machine_image
    end
  end

  def create_version_from_vm(machine_image, vm_ubid, version_str)
    vm = stopped_vms_in_location(@project, machine_image.location_id)
      .find { it.ubid == vm_ubid }

    unless vm
      fail Validation::ValidationFailed.new({vm_id: "VM not found or not stopped"})
    end

    boot_volume = vm.vm_storage_volumes.find(&:boot)

    unless boot_volume&.vhost_block_backend
      fail Validation::ValidationFailed.new({vm_id: "VM does not support image creation (requires ubiblk write tracking)"})
    end

    if Config.machine_image_max_size_gib > 0 && boot_volume.size_gib > Config.machine_image_max_size_gib
      fail Validation::ValidationFailed.new({vm_id: "Boot disk size (#{boot_volume.size_gib} GiB) exceeds maximum allowed (#{Config.machine_image_max_size_gib} GiB)"})
    end

    if MachineImageVersion.where(vm_id: vm.id, state: "creating").any?
      fail Validation::ValidationFailed.new({vm_id: "Another image is currently being created from this VM"})
    end

    next_version = version_str || MachineImage.next_auto_version(machine_image.versions_dataset)

    if machine_image.versions_dataset.where(version: next_version).any?
      fail Validation::ValidationFailed.new({version: "Version '#{next_version}' already exists"})
    end

    s3_bucket = Config.machine_image_archive_bucket
    s3_endpoint = Config.machine_image_archive_endpoint
    s3_prefix = "#{machine_image.ubid}/#{next_version}/"

    version = MachineImageVersion.create(
      machine_image_id: machine_image.id,
      version: next_version,
      state: "creating",
      vm_id: vm.id,
      size_gib: boot_volume.size_gib,
      s3_bucket: s3_bucket,
      s3_prefix: s3_prefix,
      s3_endpoint: s3_endpoint
    )
    Prog::MachineImage::Nexus.assemble(version)
    version
  end

  def stopped_vms_in_location(project, location_id)
    project.vms_dataset
      .where(location_id: location_id)
      .eager(:strand)
      .all
      .select { it.display_state == "stopped" }
      .sort_by(&:name)
  end

  def generate_machine_image_options
    stopped_vms = @project.vms_dataset.eager(:strand, :location).all
      .select { it.display_state == "stopped" }
      .sort_by(&:name)

    vm_values = stopped_vms.map {
      {location_id: it.location_id, value: it.ubid, display_name: it.name}
    }

    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "description")
    options.add_option(name: "location", values: Option.locations)
    options.add_option(name: "vm_id", values: vm_values, parent: "location") { |location, vm|
      vm[:location_id] == location.id
    }
    options.serialize
  end
end
