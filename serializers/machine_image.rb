# frozen_string_literal: true

class Serializers::MachineImage < Serializers::Base
  def self.serialize_internal(mi, options = {})
    {
      id: mi.ubid,
      name: mi.name,
      location: mi.display_location,
      arch: mi.arch,
      latest_version: mi.latest_version&.version,
      created_at: mi.created_at.iso8601,
    }
  end
end
