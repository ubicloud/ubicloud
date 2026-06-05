# frozen_string_literal: true

class Clover
  def machine_image_list
    dataset = dataset_authorize(@project.machine_images_dataset, "MachineImage:view").eager(:location, :latest_version)
    dataset = dataset.where(location_id: @location.id) if @location
    paginated_result(dataset, Serializers::MachineImage)
  end

  # Resolves the "vm" body param into an authorized Vm in @location, raising
  # 400 if the user can't see it or it's in a different location.
  def source_vm_from_params
    source_vm_id = typecast_params.ubid_uuid!("vm")
    source_vm = dataset_authorize(@project.vms_dataset, "Vm:view").first(id: source_vm_id, location_id: @location.id)
    raise CloverError.new(400, "InvalidRequest", "Source VM not found") unless source_vm
    source_vm
  end

  # Resolves the image store for @location, reads destroy_source, and kicks
  # off CreateVersionMetal. Returns the new MachineImageVersion.
  def assemble_machine_image_version(mi, version, source_vm)
    store = @project.machine_image_store_for(@location.id)
    raise CloverError.new(400, "InvalidRequest", "No machine image store configured for this location") unless store
    destroy_source = typecast_params.bool("destroy_source")
    authorize("Vm:delete", source_vm) if destroy_source
    Prog::MachineImage::CreateVersionMetal.assemble(mi, version, source_vm, store, destroy_source_after: !!destroy_source).subject
  end

  def stopped_vms_for_machine_image(location_id: nil)
    dataset = dataset_authorize(@project.vms_dataset, "Vm:view")
      .association_join(:strand)
      .where(Sequel[:strand][:label] => "stopped")
      .select_all(:vm)
      .eager(:location)
      .order(:name)
    dataset = dataset.where(Sequel[:vm][:location_id] => location_id) if location_id
    dataset.all
  end

  def generate_machine_image_options
    vm_values = stopped_vms_for_machine_image.map {
      {location_id: it.location_id, value: it.ubid, display_name: it.name}
    }

    options = OptionTreeGenerator.new
    options.add_option(name: "name")
    options.add_option(name: "location", values: Option.locations(feature_flags: @project.feature_flags))
    options.add_option(name: "vm", values: vm_values, parent: "location") { |location, vm|
      vm[:location_id] == location.id
    }
    options.add_option(name: "version")
    options.add_option(name: "destroy_source", values: ["1"])
    options.serialize
  end

  def generate_machine_image_version_options(mi)
    vm_values = stopped_vms_for_machine_image(location_id: mi.location_id).map {
      {value: it.ubid, display_name: it.name}
    }

    options = OptionTreeGenerator.new
    options.add_option(name: "version")
    options.add_option(name: "vm", values: vm_values)
    options.add_option(name: "destroy_source", values: ["1"])
    options.serialize
  end

  def machine_image_version_post(mi, version)
    authorize("MachineImage:edit", mi)
    if version && mi.versions_dataset.first(version:)
      raise CloverError.new(400, "InvalidRequest", "Version #{version} already exists for this machine image")
    end
    source_vm = source_vm_from_params

    miv = nil
    DB.transaction do
      miv = assemble_machine_image_version(mi, version, source_vm)
      audit_log(miv, "create", [mi])
    end

    if api?
      Serializers::MachineImageVersion.serialize(miv, latest_version_id: mi.latest_version_id)
    else
      flash["notice"] = "Version '#{miv.version}' is being created"
      request.redirect mi, "/versions"
    end
  end

  def machine_image_set_latest_version(mi, new_label)
    authorize("MachineImage:edit", mi)
    handle_validation_failure("machine_image/show") { @page = "settings" }

    DB.transaction do
      new_id = nil
      miv = nil
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
      audit_log(mi, "update_latest_version", miv ? [miv] : [])
    end

    if api?
      Serializers::MachineImage.serialize(mi.refresh)
    else
      flash["notice"] = "Latest version updated"
      request.redirect mi, "/settings"
    end
  end

  def machine_image_post(name)
    check_visible_location
    authorize("MachineImage:create", @project)
    Validation.validate_name(name)

    if @project.machine_images_dataset.first(location_id: @location.id, name:)
      raise CloverError.new(400, "InvalidRequest", "Machine image with this name already exists in this location")
    end

    version = typecast_params.nonempty_str("version")
    source_vm = source_vm_from_params

    mi = nil
    DB.transaction do
      mi = MachineImage.create(
        name:,
        arch: source_vm.arch,
        project_id: @project.id,
        location_id: @location.id,
      )
      miv = assemble_machine_image_version(mi, version, source_vm)
      audit_log(mi, "create", [miv])
    end

    if api?
      Serializers::MachineImage.serialize(mi)
    else
      flash["notice"] = "'#{name}' is being created"
      request.redirect mi
    end
  end
end
