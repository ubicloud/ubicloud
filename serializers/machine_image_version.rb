# frozen_string_literal: true

class Serializers::MachineImageVersion < Serializers::Base
  def self.serialize_internal(miv, options = {})
    metal = miv.metal
    vm_ubids = miv.vm_storage_volumes.map { |vsv| UBID.to_ubid(vsv.vm_id) }.sort.uniq
    {
      id: miv.ubid,
      version: miv.version,
      state: metal&.display_state,
      actual_size_mib: miv.actual_size_mib,
      archive_size_mib: metal&.archive_size_mib,
      created_at: miv.created_at.iso8601,
      vms_count: vm_ubids.size,
      vms: vm_ubids,
    }
  end
end
