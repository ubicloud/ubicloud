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
    vm_id = typecast_params.str("vm_id")

    unless @location
      fail Validation::ValidationFailed.new({location: "Location is required"})
    end

    vm = nil
    if vm_id
      vm = @project.vms_dataset.first(Sequel[:vm][:id] => UBID.to_uuid(vm_id)) ||
        @project.vms_dataset.first(Sequel[:vm][:id] => vm_id)
      fail Validation::ValidationFailed.new({vm_id: "VM not found"}) unless vm
      fail Validation::ValidationFailed.new({vm_id: "VM must be stopped"}) unless vm.display_state == "stopped"
    end

    machine_image = nil
    DB.transaction do
      machine_image = MachineImage.create(
        name:,
        description:,
        location_id: @location.id,
        project_id: @project.id,
        arch: vm ? vm.arch : "x64"
      )
      audit_log(machine_image, "create")

      if vm
        next_version = MachineImage.next_auto_version(machine_image.versions_dataset)
        s3_bucket = Config.machine_image_archive_bucket
        s3_endpoint = Config.machine_image_archive_endpoint
        s3_prefix = "#{machine_image.ubid}/#{next_version}/"

        version = MachineImageVersion.create(
          machine_image_id: machine_image.id,
          version: next_version,
          state: "creating",
          vm_id: vm.id,
          size_gib: vm.vm_storage_volumes.find(&:boot)&.size_gib || 0,
          s3_bucket: s3_bucket,
          s3_prefix: s3_prefix,
          s3_endpoint: s3_endpoint
        )
        Prog::MachineImage::Nexus.assemble(version)
        audit_log(machine_image, "update")
      end
    end

    if api?
      Serializers::MachineImage.serialize(machine_image.refresh)
    else
      flash["notice"] = "'#{name}' has been created"
      request.redirect machine_image
    end
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
    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "description")
    options.add_option(name: "location", values: Option.locations)
    options.serialize
  end
end
