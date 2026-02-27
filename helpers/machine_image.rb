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

    unless @location
      fail Validation::ValidationFailed.new({location: "Location is required"})
    end

    machine_image = nil
    DB.transaction do
      machine_image = MachineImage.create(
        name:,
        description:,
        location_id: @location.id,
        project_id: @project.id,
        arch: "x64"
      )
      audit_log(machine_image, "create")
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
