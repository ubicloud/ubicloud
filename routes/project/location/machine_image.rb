# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "machine-image") do |r|
    unless @project.get_ff_machine_image
      no_authorization_needed
      if api?
        response.status = 404
        r.halt
      else
        r.redirect @project.path
      end
    end

    r.get api? do
      machine_image_list_api_response(machine_image_list_dataset)
    end

    r.on MACHINE_IMAGE_NAME_OR_UBID do |mi_name, mi_id|
      if mi_name
        r.post api? do
          check_visible_location
          machine_image_post(mi_name)
        end

        filter = {Sequel[:machine_image][:name] => mi_name}
      else
        filter = {Sequel[:machine_image][:id] => mi_id}
      end

      filter[:location_id] = @location.id
      @machine_image = machine_image = dataset_authorize(@project.machine_images_dataset, "MachineImage:view").first(filter)
      check_found_object(machine_image)

      r.delete true do
        authorize("MachineImage:delete", machine_image)

        DB.transaction do
          machine_image.versions.each(&:incr_destroy)
          audit_log(machine_image, "destroy")
        end

        if web?
          flash["notice"] = "Machine image is being deleted"
          r.redirect @project, "/machine-image"
        else
          204
        end
      end

      r.get true do
        authorize("MachineImage:view", machine_image)

        if api?
          Serializers::MachineImage.serialize(machine_image)
        else
          r.redirect machine_image, "/overview"
        end
      end

      r.show_object(machine_image, actions: %w[overview settings], perm: "MachineImage:view", template: "machine-image/show")

      r.get web?, "create-version" do
        authorize("MachineImage:edit", machine_image)
        @stopped_vms = @project.vms_dataset
          .where(location_id: machine_image.location_id)
          .where(display_state: "stopped")
          .order(:name)
          .all
        view "machine-image/create_version"
      end

      r.post web?, "create-version" do
        authorize("MachineImage:edit", machine_image)
        handle_validation_failure("machine-image/create_version") do
          @stopped_vms = @project.vms_dataset
            .where(location_id: machine_image.location_id)
            .where(display_state: "stopped")
            .order(:name)
            .all
        end

        vm_ubid = typecast_params.nonempty_str!("vm_ubid")
        vm = @project.vms_dataset
          .where(location_id: machine_image.location_id)
          .where(display_state: "stopped")
          .first(id: UBID.to_uuid(vm_ubid))

        unless vm
          fail Validation::ValidationFailed.new({vm_ubid: "VM not found or not stopped"})
        end

        next_version = (machine_image.versions_dataset.max(:version) || 0) + 1

        DB.transaction do
          MachineImageVersion.create(
            machine_image_id: machine_image.id,
            version: next_version,
            vm_id: vm.id,
            size_gib: vm.storage_volumes.first&.size_gib || 0
          )
          audit_log(machine_image, "update")
        end

        flash["notice"] = "Version #{next_version} is being created"
        r.redirect machine_image, "/overview"
      end

      r.post web?, "set-active" do
        authorize("MachineImage:edit", machine_image)
        handle_validation_failure("machine-image/show") { @page = "overview" }

        version_ubid = typecast_params.str!("version_id")
        version = MachineImageVersion.where(
          machine_image_id: machine_image.id,
          id: UBID.to_uuid(version_ubid)
        ).first

        unless version
          fail Validation::ValidationFailed.new({version_id: "Version not found"})
        end

        DB.transaction do
          version.activate!
          audit_log(machine_image, "update")
        end

        flash["notice"] = "Version #{version.version} is now the active version"
        r.redirect machine_image, "/overview"
      end

      r.on web?, "version" do
        r.on UBID_REGEX do |version_ubid|
          version = MachineImageVersion.where(
            machine_image_id: machine_image.id,
            id: UBID.to_uuid(version_ubid)
          ).first

          r.post "delete" do
            authorize("MachineImage:edit", machine_image)
            handle_validation_failure("machine-image/show") { @page = "overview" }

            unless version
              fail Validation::ValidationFailed.new({version: "Version not found"})
            end

            if version.active?
              fail Validation::ValidationFailed.new({version: "Cannot delete the active version"})
            end

            DB.transaction do
              version.incr_destroy
              audit_log(machine_image, "update")
            end

            flash["notice"] = "Version #{version.version} is being deleted"
            r.redirect machine_image, "/overview"
          end
        end
      end
    end
  end
end
