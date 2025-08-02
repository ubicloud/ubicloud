# frozen_string_literal: true

class Serializers::Nic < Serializers::Base
  def self.serialize_internal(nic, options = {})
    {
      id: nic.ubid,
      name: nic.name,
      private_ipv4: nic.private_ipv4_address,
      private_ipv6: nic.private_ipv6_address,
      vm_name: nic.vm&.name
    }
  end
end
