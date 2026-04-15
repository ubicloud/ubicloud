# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "machine-image") do |r|
    unless @project.get_ff_machine_image
      fail Rodish::CommandFailure, "Machine image feature is not enabled for this project. Contact support to enable it."
    end

    r.get true do
      machine_image_list
    end
  end
end
