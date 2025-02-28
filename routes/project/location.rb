# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "location") do |r|
    r.on String do |location_display_name|
      next unless (@location = Location[display_name: location_display_name])

      r.hash_branches(:project_location_prefix)
    end
  end
end
