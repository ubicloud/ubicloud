# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "machine-image") do |r|
    next unless @project.get_ff_machine_image

    r.get api? do
      machine_image_list
    end

    r.web do
      r.get true do
        @machine_images = dataset_authorize(@project.machine_images_dataset, "MachineImage:view")
          .eager(:location, :latest_version)
          .order(Sequel.desc(:created_at))
          .all
        view "machine_image/index"
      end
    end
  end
end
