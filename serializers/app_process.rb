# frozen_string_literal: true

class Serializers::AppProcess < Serializers::Base
  def self.serialize_internal(process, options = {})
    {
      id: process.ubid,
      type: process.process_type,
      replica_count: process.replica_count,
      vm_size: process.vm_size,
    }
  end
end
