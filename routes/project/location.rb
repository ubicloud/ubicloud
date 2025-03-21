# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "location") do |r|
    r.on String do |location_display_name|
      @location, @location_visible = Location.where(display_name: location_display_name).get([:name, :visible])
      handle_invalid_location unless @location
      r.hash_branches(:project_location_prefix)
    end
  end
end
