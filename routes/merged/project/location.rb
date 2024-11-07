# frozen_string_literal: true

class Clover
  branch = lambda do |r|
    r.on String do |location_display_name|
      @location = LocationNameConverter.to_internal_name(location_display_name)

      r.hash_branches(api? ? :api_project_location_prefix : :project_location_prefix)
    end
  end

  hash_branch(:project_prefix, "location", &branch)
  hash_branch(:api_project_prefix, "location", &branch)
end
