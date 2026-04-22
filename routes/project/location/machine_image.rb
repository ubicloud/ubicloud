# frozen_string_literal: true

class Clover
  hash_branch(:project_location_prefix, "machine-image") do |r|
    require_machine_image_feature!

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

      r.get api?, true do
        authorize("MachineImage:view", mi)
        Serializers::MachineImage.serialize(mi, {detailed: true})
      end

      r.patch api?, true do
        machine_image_update(mi)
      end

      r.delete api?, true do
        machine_image_destroy(mi)
      end

      r.post api?, "rename" do
        machine_image_rename(mi)
      end
    end
  end
end
