# frozen_string_literal: true

class Clover
  def require_machine_image_feature!
    unless @project.get_ff_machine_image
      no_authorization_needed
      fail CloverError.new(400, "FeatureNotEnabled", "Machine image feature is not enabled for this project. Contact support to enable it.")
    end
  end

  # Validates that the source VM is in a state that allows it to be archived.
  # The Prog::MachineImage::VersionMetalNexus.assemble_from_vm prog also asserts
  # these but raises plain RuntimeError; running these checks here surfaces as
  # 400 InvalidRequest instead of 500 InternalServerError.
  def validate_source_vm_for_archive(source_vm)
    raise CloverError.new(400, "InvalidRequest", "Source VM must be a metal VM") unless source_vm.vm_host
    raise CloverError.new(400, "InvalidRequest", "Source VM must have only one storage volume") unless source_vm.vm_storage_volumes.count == 1
    raise CloverError.new(400, "InvalidRequest", "Source VM must be stopped") unless source_vm.display_state == "stopped"
    sv = source_vm.vm_storage_volumes.first
    raise CloverError.new(400, "InvalidRequest", "Source VM's vhost block backend must support archive") unless sv.vhost_block_backend&.supports_archive?
    raise CloverError.new(400, "InvalidRequest", "Source VM's storage volume must be encrypted") unless sv.key_encryption_key_1
  end

  def machine_image_list
    dataset = dataset_authorize(@project.machine_images_dataset, "MachineImage:view").eager(:location, :latest_version)

    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset, Serializers::MachineImage)
  end

  def machine_image_post(name)
    project = @project
    authorize("MachineImage:create", project)
    Validation.validate_name(name)

    if project.machine_images_dataset.first(location_id: @location.id, name:)
      raise CloverError.new(400, "InvalidRequest", "Machine image with this name already exists in this location")
    end

    source_vm_id = typecast_params.nonempty_str!("vm")
    version = typecast_params.nonempty_str("version") || Time.now.strftime("%Y%m%d%H%M%S")
    Validation.validate_machine_image_version_label(version)
    destroy_source = typecast_params.bool("destroy_source")

    source_vm = dataset_authorize(project.vms_dataset, "Vm:view").first(id: UBID.to_uuid(source_vm_id))
    raise CloverError.new(400, "InvalidRequest", "Source VM not found") unless source_vm
    validate_source_vm_for_archive(source_vm)

    store = project.machine_image_stores_dataset.first(location_id: @location.id)
    raise CloverError.new(400, "InvalidRequest", "No machine image store configured for this location") unless store

    DB.transaction do
      mi = MachineImage.create(
        name:,
        arch: source_vm.arch,
        project_id: project.id,
        location_id: @location.id,
      )

      miv = Prog::MachineImage::VersionMetalNexus.assemble_from_vm(mi, version, source_vm, store, destroy_source_after: !!destroy_source).subject

      audit_log(mi, "create", [miv])
      Serializers::MachineImage.serialize(mi, {detailed: true})
    end
  end

  def machine_image_update(mi)
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
end
