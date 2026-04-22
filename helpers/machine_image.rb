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
    destroy_source = typecast_params.bool("destroy_source")

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

  def machine_image_version_list(mi)
    authorize("MachineImage:view", mi)
    versions = mi.versions_dataset.eager(:metal).order(Sequel.desc(:created_at)).all
    {
      items: Serializers::MachineImageVersion.serialize(versions),
      count: versions.count,
    }
  end

  def machine_image_create_version(mi, version)
    authorize("MachineImage:edit", mi)

    source_vm_id = typecast_params.nonempty_str!("vm")
    destroy_source = typecast_params.bool("destroy_source")

    source_vm = @project.vms_dataset.first(id: UBID.to_uuid(source_vm_id))
    unless source_vm
      raise CloverError.new(400, "InvalidRequest", "Source VM not found")
    end

    if source_vm.arch != mi.arch
      raise CloverError.new(400, "InvalidRequest", "Source VM arch (#{source_vm.arch}) does not match machine image arch (#{mi.arch})")
    end

    store = MachineImageStore.where(project_id: @project.id, location_id: @location.id).first
    unless store
      raise CloverError.new(400, "InvalidRequest", "No machine image store configured for this location")
    end

    miv = nil
    DB.transaction do
      Prog::MachineImage::CreateVersionMetal.assemble(mi, version, source_vm, store, destroy_source_after: !!destroy_source)
      miv = mi.versions_dataset.first(version: version)
      audit_log(mi, "create_version")
    end

    Serializers::MachineImageVersion.serialize(miv)
  end

  def machine_image_destroy_version(mi, version)
    authorize("MachineImage:delete", mi)

    miv = mi.versions_dataset.first(version: version)
    check_found_object(miv)

    unless miv.metal
      raise CloverError.new(400, "InvalidRequest", "Version has no metal record to destroy")
    end

    if mi.latest_version_id == miv.id
      raise CloverError.new(400, "InvalidRequest", "Cannot destroy the latest version of a machine image")
    end

    unless miv.metal.vm_storage_volumes_dataset.empty?
      raise CloverError.new(400, "InvalidRequest", "VMs are still using this machine image version")
    end

    DB.transaction do
      Prog::MachineImage::DestroyVersionMetal.assemble(miv.metal)
      audit_log(mi, "destroy_version")
    end

    204
  end
end
