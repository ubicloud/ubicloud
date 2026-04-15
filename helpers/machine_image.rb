# frozen_string_literal: true

class Clover
  def machine_image_list
    dataset = dataset_authorize(@project.machine_images_dataset, "MachineImage:view").eager(:location, :latest_version)

    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset, Serializers::MachineImage)
  end

  def machine_image_post(name)
    project = @project
    authorize("MachineImage:create", project)

    source_vm_id = typecast_params.nonempty_str!("vm")
    version = typecast_params.nonempty_str("version") || Time.now.strftime("%Y%m%d%H%M%S")
    destroy_source = typecast_params.convert! { it.bool("destroy_source") }[:destroy_source]

    source_vm = project.vms_dataset.first(id: UBID.to_uuid(source_vm_id))
    unless source_vm
      raise CloverError.new(400, "InvalidRequest", "Source VM not found")
    end

    store = MachineImageStore.where(project_id: project.id, location_id: @location.id).first
    unless store
      raise CloverError.new(400, "InvalidRequest", "No machine image store configured for this location")
    end

    mi = nil
    DB.transaction do
      mi = MachineImage.create(
        name: name,
        arch: source_vm.arch,
        project_id: project.id,
        location_id: @location.id,
      )

      Prog::MachineImage::CreateVersionMetal.assemble(mi, version, source_vm, store, destroy_source_after: !!destroy_source)

      audit_log(mi, "create")
    end

    Serializers::MachineImage.serialize(mi, {detailed: true})
  end
end
