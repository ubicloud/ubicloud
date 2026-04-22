# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "machine-image") do |r|
    next unless @project.get_ff_machine_image

    r.get api? do
      machine_image_list
    end
  end
end
