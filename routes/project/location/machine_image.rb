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
          authorize("MachineImage:create", @project)
          vm_id = typecast_params.nonempty_str!("vm_id")
          vm = @project.vms_dataset.where(id: UBID.to_uuid(vm_id)).first
          unless vm
            fail Validation::ValidationFailed.new({vm_id: "VM not found"})
          end
          machine_image_post(vm, mi_name)
        end

        filter = {Sequel[:machine_image][:name] => mi_name}
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
          view "machine-image/show"
        end
      end
    end
  end
end
