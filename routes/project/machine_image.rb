# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "machine-image") do |r|
    r.get true do
      dataset = machine_image_list_dataset

      if api?
        machine_image_list_api_response(dataset)
      else
        @machine_images = dataset.eager(:location, :vm).order(Sequel.desc(:created_at)).all
        view "machine-image/index"
      end
    end

    r.web do
      r.get "create" do
        authorize("MachineImage:create", @project)
        view "machine-image/create"
      end

      r.post true do
        handle_validation_failure("machine-image/create")
        check_visible_location
        machine_image_post(typecast_params.nonempty_str("name"))
      end
    end
  end
end
