# frozen_string_literal: true

class Clover
  def machine_image_list_dataset
    project_images = dataset_authorize(@project.machine_images_dataset, "MachineImage:view").active_versions
    public_images = MachineImage.where(visible: true).exclude(project_id: @project.id).active_versions
    project_images.union(public_images)
  end

  def machine_image_list_api_response(dataset)
    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset.eager(:location, :vm).order(Sequel.desc(:created_at)), Serializers::MachineImage)
  end

  def machine_image_post(vm, name = nil)
    authorize("MachineImage:create", @project)
    inline = !vm.nil? # true when called from VM show page

    name ||= typecast_params.nonempty_str!("name")
    Validation.validate_name(name)
    description = typecast_params.str("description") || ""

    # If vm not provided directly (standalone create form), look up by vm_id param
    unless vm
      vm_ubid = typecast_params.str!("vm_id")
      vm = dataset_authorize(@project.vms_dataset, "Vm:view").first(id: UBID.to_uuid(vm_ubid))
      unless vm
        fail Validation::ValidationFailed.new({vm_id: "VM with the given id \"#{vm_ubid}\" is not found"})
      end
    end

    unless vm.display_state == "stopped"
      fail Validation::ValidationFailed.new({vm_id: "VM must be in 'stopped' state to create a machine image. Current state: '#{vm.display_state}'. Please stop the VM and try again."})
    end

    if @location && vm.location_id != @location.id
      fail Validation::ValidationFailed.new({vm_id: "VM must be in the same location as the machine image"})
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

    Validation.validate_machine_image_quota(@project)

    location = vm.location
    existing_count = MachineImage.where(project_id: @project.id, location_id: location.id, name:).count
    version = "v#{existing_count + 1}"

    machine_image = nil
    DB.transaction do
      MachineImage.where(project_id: @project.id, location_id: location.id, name:).update(active: false)

      machine_image = MachineImage.create(
        name:,
        description:,
        version:,
        location_id: location.id,
        project_id: @project.id,
        state: "creating",
        vm_id: vm.id,
        size_gib: boot_size_gib,
        arch: vm.arch,
        encrypted: true,
        active: true,
        s3_bucket: Config.machine_image_archive_bucket || "",
        s3_prefix: "#{@project.ubid}/#{location.display_name}/",
        s3_endpoint: Config.machine_image_archive_endpoint || ""
      )
      machine_image.update(s3_prefix: "#{machine_image.s3_prefix}#{machine_image.ubid}/")
      Strand.create(id: machine_image.id, prog: "MachineImage::Nexus", label: "start", stack: [{"subject_id" => machine_image.id}])
      audit_log(machine_image, "create")
    end

    if api?
      Serializers::MachineImage.serialize(machine_image)
    elsif inline
      flash["notice"] = "'#{name}' image is being created"
      request.redirect vm
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
