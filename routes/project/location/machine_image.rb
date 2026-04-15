# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "machine-image") do |r|
    unless @project.get_ff_machine_image
      fail Rodish::CommandFailure, "Machine image feature is not enabled for this project. Contact support to enable it."
    end

    r.get api? do
      machine_image_list
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
      mi = @project.machine_images_dataset.first(filter)
      check_found_object(mi)

      r.get true do
        authorize("MachineImage:view", mi)
        Serializers::MachineImage.serialize(mi, {detailed: true})
      end

      r.delete true do
        authorize("MachineImage:delete", mi)

        DB.transaction do
          mi.versions.each do |v|
            next unless v.metal
            Prog::MachineImage::DestroyVersionMetal.assemble(v.metal)
          end
          audit_log(mi, "destroy")
        end

        204
      end
    end
  end
end
