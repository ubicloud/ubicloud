# frozen_string_literal: true

class Clover
  def machine_image_list
    dataset = dataset_authorize(@project.machine_images_dataset, "MachineImage:view").eager(:location, :latest_version)

    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset, Serializers::MachineImage)
  end

  # Resolves the "vm" request param into an authorised Vm in @location,
  # raising a 400 if the user can't see it or if it's in a different location.
  def source_vm_from_params
    source_vm_id = typecast_params.nonempty_str!("vm")
    source_vm = dataset_authorize(@project.vms_dataset, "Vm:view").first(id: UBID.to_uuid(source_vm_id), location_id: @location.id)
    raise CloverError.new(400, "InvalidRequest", "Source VM not found") unless source_vm
    source_vm
  end

  # Resolves the image store for @location (project-owned, or the platform
  # default), then reads destroy_source and kicks off CreateVersionMetal.
  # Returns the new MachineImageVersion.
  def assemble_version(mi, version, source_vm)
    store = @project.machine_image_store_for(@location.id)
    raise CloverError.new(400, "InvalidRequest", "No machine image store configured for this location") unless store
    destroy_source = typecast_params.bool("destroy_source")
    Prog::MachineImage::CreateVersionMetal.assemble(mi, version, source_vm, store, destroy_source_after: !!destroy_source).subject
  end

  def machine_image_post(name)
    authorize("MachineImage:create", @project)
    Validation.validate_name(name)

    if @project.machine_images_dataset.first(location_id: @location.id, name:)
      raise CloverError.new(400, "InvalidRequest", "Machine image with this name already exists in this location")
    end

    version = typecast_params.nonempty_str("version") || Time.now.utc.strftime("%Y%m%d%H%M%S")
    Validation.validate_machine_image_version_label(version)
    source_vm = source_vm_from_params

    DB.transaction do
      mi = MachineImage.create(
        name:,
        arch: source_vm.arch,
        project_id: @project.id,
        location_id: @location.id,
      )
      miv = assemble_version(mi, version, source_vm)
      audit_log(mi, "create", [miv])
      Serializers::MachineImage.serialize(mi, {detailed: true})
    end
  end

  def machine_image_set_latest(mi)
    authorize("MachineImage:edit", mi)

    new_label = typecast_params.str("latest_version")

    DB.transaction do
      new_id = nil
      if new_label
        miv = mi.versions_dataset.first(version: new_label)
        raise CloverError.new(400, "InvalidRequest", "Version #{new_label} not found") unless miv
        # FOR SHARE conflicts with destroy_version's UPDATE on the metal row, so
        # the enabled check below is consistent with what destroy_version commits.
        metal = miv.metal_dataset.for_share.first
        raise CloverError.new(400, "InvalidRequest", "Version #{new_label} is not ready") unless metal&.enabled
        new_id = miv.id
      end
      mi.update(latest_version_id: new_id)
      audit_log(mi, "update")
    end

    Serializers::MachineImage.serialize(mi.refresh, {detailed: true})
  end

  def machine_image_destroy(mi)
    authorize("MachineImage:delete", mi)

    if mi.versions_dataset.any?
      raise CloverError.new(400, "InvalidRequest", "Machine image still has versions; destroy them first")
    end

    DB.transaction do
      audit_log(mi, "destroy")
      mi.destroy
    end

    204
  end

  def machine_image_rename(mi)
    authorize("MachineImage:edit", mi)

    name = typecast_body_params.nonempty_str!("name")
    if name == mi.name
      no_audit_log
    else
      Validation.validate_name(name)
      DB.transaction do
        mi.update(name:)
        audit_log(mi, "update")
      end
    end

    Serializers::MachineImage.serialize(mi)
  end

  def machine_image_version_list(mi)
    authorize("MachineImage:view", mi)
    paginated_result(mi.versions_dataset.eager(:metal), Serializers::MachineImageVersion)
  end

  def machine_image_create_version(mi, version)
    authorize("MachineImage:edit", mi)

    if mi.versions_dataset.first(version:)
      raise CloverError.new(400, "InvalidRequest", "Version #{version} already exists for this machine image")
    end

    source_vm = source_vm_from_params

    DB.transaction do
      miv = assemble_version(mi, version, source_vm)
      audit_log(mi, "create_version", [miv])
      Serializers::MachineImageVersion.serialize(miv)
    end
  end

  def machine_image_destroy_version(mi, version)
    authorize("MachineImage:edit", mi)

    miv = mi.versions_dataset.first(version:)
    raise CloverError.new(404, "ResourceNotFound", "Machine image version not found") unless miv

    metal = miv.metal
    raise CloverError.new(400, "InvalidRequest", "Version has no metal record to destroy") unless metal

    DB.transaction do
      Prog::MachineImage::DestroyVersionMetal.assemble(metal)
      audit_log(mi, "destroy_version", [miv])
    end

    204
  end
end
