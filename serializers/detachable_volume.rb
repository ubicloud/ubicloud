# frozen_string_literal: true

class Serializers::DetachableVolume < Serializers::Base
  def self.serialize_internal(dv, options = {})
    {
      id: dv.ubid,
      name: dv.name,
      size_gib: dv.size_gib,
      state: dv.display_state,
      vm_id: dv.vm_id && UBID.from_uuidish(dv.vm_id).to_s,
      encrypted: dv.encrypted?
    }
  end
end
