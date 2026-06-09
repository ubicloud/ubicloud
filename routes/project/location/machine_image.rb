# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "machine-image") do |r|
    next unless @project.get_ff_machine_image

    r.get api? do
      machine_image_list
    end

    r.on MACHINE_IMAGE_NAME_OR_UBID do |mi_name, mi_id|
      if mi_name
        r.post api? do
          machine_image_post(mi_name)
        end

        filter = {Sequel[:machine_image][:name] => mi_name}
      else
        filter = {Sequel[:machine_image][:id] => mi_id}
      end

      filter[:location_id] = @location.id
      @machine_image = mi = @project.machine_images_dataset.first(filter)
      check_found_object(mi)

      r.get true do
        authorize("MachineImage:view", mi)
        if api?
          Serializers::MachineImage.serialize(mi)
        else
          r.redirect mi, "/overview"
        end
      end

      r.patch api? do
        machine_image_set_latest_version(mi, typecast_params.nonempty_str!("latest_version"))
      end

      r.post web?, "set-latest-version" do
        machine_image_set_latest_version(mi, typecast_params.nonempty_str!("latest_version"))
      end

      r.delete true do
        authorize("MachineImage:delete", mi)
        handle_validation_failure("machine_image/show") { @page = "settings" }
        unless mi.versions_dataset.empty?
          raise CloverError.new(400, "InvalidRequest", "Machine image still has versions; destroy them first")
        end

        DB.transaction do
          audit_log(mi, "destroy")
          mi.destroy
        end

        if api?
          204
        else
          flash["notice"] = "Machine image '#{mi.name}' is deleted"
          r.redirect @project, "/machine-image"
        end
      end

      r.rename(mi, perm: "MachineImage:edit", serializer: Serializers::MachineImage, template_prefix: "machine_image")

      r.get web?, "create-version" do
        authorize("MachineImage:edit", mi)
        @page_title = "Create Version - #{mi.name}"
        view "machine_image/create_version"
      end

      r.on "version" do
        r.get api? do
          authorize("MachineImage:view", mi)
          paginated_result(mi.versions_dataset.eager(:metal), Serializers::MachineImageVersion, latest_version_id: mi.latest_version_id)
        end

        r.post web? do
          handle_validation_failure("machine_image/create_version")
          machine_image_version_post(mi, typecast_params.nonempty_str("version"))
        end

        r.on(/([a-zA-Z0-9][a-zA-Z0-9._-]{0,63})/) do |version|
          r.post api? do
            machine_image_version_post(mi, version)
          end

          r.delete true do
            authorize("MachineImage:edit", mi)
            handle_validation_failure("machine_image/show") { @page = "versions" }
            miv = mi.versions_dataset.first(version:)
            raise CloverError.new(404, "ResourceNotFound", "Machine image version not found") unless miv
            metal = miv.metal
            raise CloverError.new(400, "InvalidRequest", "Version has no metal record to destroy") unless metal

            DB.transaction do
              Prog::MachineImage::DestroyVersionMetal.assemble(metal)
              audit_log(miv, "destroy", [mi])
            end

            if api?
              204
            else
              flash["notice"] = "Version '#{version}' is being deleted"
              r.redirect mi, "/versions"
            end
          end
        end
      end

      r.show_object(mi, actions: %w[overview versions settings], perm: "MachineImage:view", template: "machine_image/show")
    end
  end
end
