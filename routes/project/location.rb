# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "location") do |r|
    r.on String do |location_display_name|
      check_visible_location(location_display_name)
      r.hash_branches(:project_location_prefix)
    end
  end
end
