# frozen_string_literal: true

class Serializers::MachineImage < Serializers::Base
  def self.serialize_internal(mi, options = {})
    active_ver = mi.active_version

    base = {
      id: mi.ubid,
      name: mi.name,
      description: mi.description,
      visible: mi.visible,
      location: mi.display_location,
      created_at: mi.created_at&.iso8601,
      active_version: active_ver ? serialize_version(active_ver) : nil,
      versions: mi.versions.map { serialize_version(it) }
    }

    if options[:include_path]
      base[:path] = mi.path
    end

    base
  end

  def self.serialize_version(ver)
    {
      id: ver.ubid,
      version: ver.version,
      state: ver.state,
      size_gib: ver.size_gib,
      arch: ver.arch,
      active: ver.active?,
      source_vm_id: ver.vm&.ubid,
      activated_at: ver.activated_at&.iso8601,
      created_at: ver.created_at&.iso8601
    }
  end
end
