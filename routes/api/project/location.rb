# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "location") do |r|
    r.on String do |location_name|
      @location = location_name

      r.hash_branches(:project_location_prefix)
    end
  end
end
