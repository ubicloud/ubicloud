# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "machine-image") do |r|
    require_machine_image_feature!

    r.get api?, true do
      machine_image_list
    end
  end
end
