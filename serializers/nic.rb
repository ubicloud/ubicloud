# frozen_string_literal: true

class Serializers::Nic < Serializers::Base
  def self.serialize_internal(nic, options = {})
    {
      id: nic.ubid,
      name: nic.name,
      private_ipv4: nic.private_ipv4.network.to_s,
      private_ipv6: nic.private_ipv6.nth(2).to_s,
      vm_name: nic.vm&.name
    }
  end
end
