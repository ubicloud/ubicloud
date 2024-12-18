# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "location") do |r|
    r.on String do |location_display_name|
      @location = LocationNameConverter.to_internal_name(location_display_name)

      r.hash_branches(:project_location_prefix)
    end
  end
end
