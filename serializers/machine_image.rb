# frozen_string_literal: true

class Serializers::MachineImage < Serializers::Base
  def self.serialize_internal(mi, options = {})
    base = {
      id: mi.ubid,
      name: mi.name,
      location: mi.display_location,
      arch: mi.arch,
      latest_version: mi.latest_version&.version,
      created_at: mi.created_at&.iso8601,
    }

    if options[:detailed]
      versions = mi.versions.map do |v|
        {
          id: v.ubid,
          version: v.version,
          state: v.metal&.enabled ? "available" : "creating",
          created_at: v.created_at&.iso8601,
        }
      end
      base[:versions] = versions
    end

    base
  end
end
