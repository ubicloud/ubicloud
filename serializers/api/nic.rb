# frozen_string_literal: true

class Serializers::Api::Nic < Serializers::Base
  def self.base(nic)
    {
      ubid: nic.ubid,
      name: nic.name,
      private_ipv4: nic.private_ipv4.network.to_s,
      private_ipv6: nic.private_ipv6.nth(2).to_s,
      vm_name: nic.vm&.name,
      vm_id: nic.vm&.ubid,
      subnet_name: nic.private_subnet.name,
      subnet_id: nic.private_subnet.ubid
    }
  end

  structure(:default) do |nic|
    base(nic)
  end
end
