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

  def stopped_vms_for_mi(location_id: nil)
    # Pre-filter at the DB level on strand.label == "stopped". The
    # display_state == "stopped" check below catches the residual cases
    # where a semaphore (destroy, restart, ...) has been incremented but
    # the strand hasn't moved off the "stopped" label yet.
    dataset = dataset_authorize(@project.vms_dataset, "Vm:view")
      .association_join(:strand).where(Sequel[:strand][:label] => "stopped")
      .select_all(:vm).eager(:strand, :location)
    dataset = dataset.where(Sequel[:vm][:location_id] => location_id) if location_id
    dataset.all.select { it.display_state == "stopped" }.sort_by(&:name)
  end

  def generate_mi_options
    vm_values = stopped_vms_for_mi.map {
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

  def generate_mi_version_options(mi)
    vm_values = stopped_vms_for_mi(location_id: mi.location_id).map {
      {value: it.ubid, display_name: it.name}
    }

    options = OptionTreeGenerator.new
    options.add_option(name: "version")
    options.add_option(name: "vm", values: vm_values)
    options.add_option(name: "destroy_source", values: ["1"])
    options.serialize
  end
end
