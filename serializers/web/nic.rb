# frozen_string_literal: true

class Serializers::Web::Nic < Serializers::Base
  def self.base(nic)
    {
      id: nic.id,
      ubid: nic.ubid,
      name: nic.name,
      private_ipv4: nic.private_ipv4.network.to_s,
      private_ipv6: nic.private_ipv6.nth(2).to_s,
      vm_name: nic.vm&.name,
      subnet_name: nic.private_subnet.name
    }
  end

  structure(:default) do |nic|
    base(nic)
  end
end
