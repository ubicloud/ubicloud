# frozen_string_literal: true

class Serializers::PostgresServer < Serializers::Base
  def self.serialize_internal(server, options = {})
    {
      id: server.ubid,
      role: server.is_representative ? "primary" : "standby",
      state: server.display_state,
      synchronization_status: server.synchronization_status,
      vm_size: server.vm.display_size,
      target_vm_size: server.target_vm_size,
      on_intended_type: server.on_intended_type?,
      vm: Serializers::Vm.serialize(server.vm),
    }
  end
end
