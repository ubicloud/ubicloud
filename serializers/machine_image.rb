# frozen_string_literal: true

class Serializers::MachineImage < Serializers::Base
  def self.serialize_internal(mi, options = {})
    base = {
      id: mi.ubid,
      name: mi.name,
      location: mi.display_location,
      arch: mi.arch,
      latest_version: mi.latest_version&.version,
      created_at: mi.created_at.iso8601,
    }

    if options[:detailed]
      visible_vms = options[:visible_vms] || []
      versions = mi.versions_dataset.eager(:metal, vm_storage_volumes: ->(ds) { ds.where(vm_id: visible_vms) }).all
      base[:versions] = Serializers::MachineImageVersion.serialize(versions)
    end

    base
  end
end
