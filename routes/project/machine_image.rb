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
  end
end
