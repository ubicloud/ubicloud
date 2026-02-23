# frozen_string_literal: true

class Clover
  def machine_image_list_dataset
    project_images = dataset_authorize(@project.machine_images_dataset, "MachineImage:view")
    public_images = MachineImage.where(visible: true).exclude(project_id: @project.id)
    project_images.union(public_images).exclude(state: "decommissioned")
  end

  def machine_image_list_api_response(dataset)
    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset.eager(:location, :vm).order(Sequel.desc(:created_at)), Serializers::MachineImage)
  end

  def machine_image_post(vm, name = nil)
    authorize("MachineImage:create", @project)

    name ||= typecast_params.nonempty_str!("name")
    Validation.validate_name(name)
    description = typecast_params.str("description") || ""

    unless vm.display_state == "stopped"
      fail Validation::ValidationFailed.new({vm_id: "VM must be in 'stopped' state to create a machine image. Current state: '#{vm.display_state}'. Please stop the VM and try again."})
    end

    boot_vol = vm.vm_storage_volumes.find(&:boot)
    boot_size_gib = boot_vol ? boot_vol.size_gib : 0
    max_size_gib = Config.machine_image_max_size_gib
    if boot_size_gib > max_size_gib
      fail Validation::ValidationFailed.new({vm_id: "VM boot disk size (#{boot_size_gib} GiB) exceeds maximum image size (#{max_size_gib} GiB)"})
    end

    if MachineImage.where(vm_id: vm.id).exclude(state: ["available", "failed", "destroying"]).any?
      fail Validation::ValidationFailed.new({vm_id: "A machine image is already being created from this VM"})
    end

    if MachineImage.where(project_id: @project.id, location_id: vm.location_id, name:).any?
      fail Validation::ValidationFailed.new({name: "A machine image with this name already exists in this location"})
    end

    Validation.validate_machine_image_quota(@project)

    machine_image = nil
    DB.transaction do
      machine_image = MachineImage.create(
        name:,
        description:,
        location_id: vm.location_id,
        project_id: @project.id,
        state: "creating",
        vm_id: vm.id,
        size_gib: boot_size_gib,
        arch: vm.arch,
        encrypted: true,
        s3_bucket: Config.machine_image_archive_bucket || "",
        s3_prefix: "#{@project.ubid}/#{vm.location.display_name}/",
        s3_endpoint: Config.machine_image_archive_endpoint || ""
      )
      machine_image.update(s3_prefix: "#{machine_image.s3_prefix}#{machine_image.ubid}/")
      Strand.create(id: machine_image.id, prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => machine_image.id}])
      audit_log(machine_image, "create")
    end

    if api?
      Serializers::MachineImage.serialize(machine_image)
    else
      flash["notice"] = "'#{name}' image is being created"
      request.redirect vm
    end
  end
end
