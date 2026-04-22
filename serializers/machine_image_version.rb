# frozen_string_literal: true

class Serializers::MachineImageVersion < Serializers::Base
  def self.serialize_internal(miv, options = {})
    metal = miv.metal
    {
      id: miv.ubid,
      version: miv.version,
      state: metal&.display_state,
      actual_size_mib: miv.actual_size_mib,
      archive_size_mib: metal&.archive_size_mib,
      created_at: miv.created_at.iso8601,
    }
  end
end
