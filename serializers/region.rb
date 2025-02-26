# frozen_string_literal: true

class Serializers::Region < Serializers::Base
  def self.serialize_internal(r, options = {})
    {
      id: r.ubid,
      name: r.location.display_name,
      aws_region_name: r.location.name,
      project_name: r.project.name,
      path: r.path
    }
  end
end
