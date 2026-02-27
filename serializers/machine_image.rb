# frozen_string_literal: true

class Serializers::MachineImage < Serializers::Base
  def self.serialize_internal(mi, options = {})
    active_ver = mi.active_version
    # Fall back to latest version for top-level fields when no active version
    latest_ver = active_ver || mi.versions.first

    base = {
      id: mi.ubid,
      name: mi.name,
      description: mi.description,
      location: mi.display_location,
      arch: mi.arch,
      version: latest_ver&.version,
      state: latest_ver&.state,
      size_gib: latest_ver&.size_gib,
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
      archive_size_mib: ver.archive_size_mib,
      active: ver.active?,
      source_vm_id: ver.vm&.ubid,
      activated_at: ver.activated_at&.iso8601,
      created_at: ver.created_at&.iso8601
    }
  end
end
