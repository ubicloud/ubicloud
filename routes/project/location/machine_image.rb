# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "machine-image") do |r|
    r.get api? do
      machine_image_list_api_response(machine_image_list_dataset)
    end

    r.on MACHINE_IMAGE_NAME_OR_UBID do |mi_name, mi_id|
      if mi_name
        r.post api? do
          check_visible_location
          machine_image_post(mi_name)
        end

        filter = {Sequel[:machine_image][:name] => mi_name, Sequel[:machine_image][:active] => true}
      else
        filter = {Sequel[:machine_image][:id] => mi_id}
      end

      filter[:location_id] = @location.id
      @machine_image = machine_image = MachineImage.for_project(@project.id).first(filter)
      check_found_object(machine_image)

      owned = machine_image.project_id == @project.id

      r.delete true do
        authorize("MachineImage:delete", machine_image)

        DB.transaction do
          machine_image.incr_destroy
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
        if owned
          authorize("MachineImage:view", machine_image)
        else
          no_authorization_needed
        end

        if api?
          Serializers::MachineImage.serialize(machine_image)
        else
          r.redirect machine_image, "/overview"
        end
      end

      if owned
        r.show_object(machine_image, actions: %w[overview versions settings], perm: "MachineImage:view", template: "machine-image/show")

        r.post web?, "set-active" do
          authorize("MachineImage:edit", machine_image)

          version_ubid = typecast_params.str!("version_id")
          version = MachineImage.where(
            project_id: machine_image.project_id,
            location_id: machine_image.location_id,
            name: machine_image.name,
            id: UBID.to_uuid(version_ubid)
          ).first

          unless version
            fail Validation::ValidationFailed.new({version_id: "Version not found"})
          end

          DB.transaction do
            version.set_active!
            audit_log(version, "update")
          end

          flash["notice"] = "Version '#{version.version}' is now the active version"
          r.redirect machine_image, "/versions"
        end
      else
        # Public images from other projects: read-only overview, no settings
        r.web do
          r.get "overview" do
            no_authorization_needed
            response.headers["cache-control"] = "no-store"
            @page = "overview"
            view "machine-image/show"
          end
        end
      end
    end
  end
end
