# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "location") do |r|
    r.on String do |location_display_name|
      # Do not allow access to locations tied to other projects
      handle_invalid_location unless (@location = Location.for_project(@project.id)[display_name: location_display_name])
      r.hash_branches(:project_location_prefix)
    end
  end
end
