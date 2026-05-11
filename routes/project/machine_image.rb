# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "machine-image") do |r|
    next unless @project.get_ff_machine_image

    r.get api? do
      machine_image_list
    end

    r.web do
      r.get true do
        authorize("MachineImage:view", @project)
        @machine_images = dataset_authorize(@project.machine_images_dataset, "MachineImage:view")
          .eager(:location, :latest_version)
          .order(Sequel.desc(:created_at))
          .all
        view "machine_image/index"
      end

      r.post true do
        handle_validation_failure("machine_image/create")
        authorize("MachineImage:create", @project)
        check_visible_location
        mi_name = typecast_params.nonempty_str!("name")
        Validation.validate_name(mi_name)

        if @project.machine_images_dataset.first(location_id: @location.id, name: mi_name)
          raise CloverError.new(400, "InvalidRequest", "Machine image with this name already exists in this location")
        end

        version = typecast_params.nonempty_str("version") || Time.now.utc.strftime("%Y%m%d%H%M%S")
        Validation.validate_machine_image_version_label(version)
        source_vm = source_vm_from_params

        mi = DB.transaction do
          MachineImage.create(
            name: mi_name,
            arch: source_vm.arch,
            project_id: @project.id,
            location_id: @location.id,
          ).tap do |new_mi|
            miv = assemble_machine_image_version(new_mi, version, source_vm)
            audit_log(new_mi, "create", [miv])
          end
        end

        flash["notice"] = "'#{mi_name}' is being created"
        r.redirect mi
      end

      r.get "create" do
        authorize("MachineImage:create", @project)
        view "machine_image/create"
      end
    end
  end
end
