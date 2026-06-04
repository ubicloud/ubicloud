# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "machine-image") do |r|
    next unless @project.get_ff_machine_image

    r.get api? do
      machine_image_list
    end

    r.web do
      r.is do
        r.get do
          @machine_images = dataset_authorize(@project.machine_images_dataset, "MachineImage:view")
            .eager(:location, :latest_version)
            .reverse(:created_at)
            .all
          view "machine_image/index"
        end

        r.post do
          handle_validation_failure("machine_image/create")
          machine_image_post(typecast_params.nonempty_str!("name"))
        end
      end

      r.get "create" do
        authorize("MachineImage:create", @project)
        view "machine_image/create"
      end
    end
  end
end
