# frozen_string_literal: true

class CloverApi
  hash_branch(:api_project_prefix, "location") do |r|
    r.on String do |location_display_name|
      @location = LocationNameConverter.to_internal_name(location_display_name)

      r.hash_branches(:api_project_location_prefix)
    end
  end
end
