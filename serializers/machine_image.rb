# frozen_string_literal: true

class Serializers::MachineImage < Serializers::Base
  def self.serialize_internal(mi, options = {})
    base = {
      id: mi.ubid,
      name: mi.name,
      description: mi.description,
      state: mi.state,
      size_gib: mi.size_gib,
      encrypted: mi.encrypted,
      compression: mi.compression,
      visible: mi.visible,
      location: mi.display_location,
      source_vm_id: mi.vm&.ubid,
      created_at: mi.created_at&.iso8601
    }

    if options[:include_path]
      base[:path] = mi.path
    end

    base
  end
end
