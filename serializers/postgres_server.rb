# frozen_string_literal: true

class Serializers::PostgresServer < Serializers::Base
  def self.serialize_internal(server, options = {})
    {
      id: server.ubid,
      role: server.is_representative ? "primary" : "standby",
      state: server.display_state,
      synchronization_status: server.synchronization_status,
      vm: Serializers::Vm.serialize(server.vm)
    }
  end
end
