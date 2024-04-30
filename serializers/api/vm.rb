# frozen_string_literal: true

require_relative "../base"

class Serializers::Api::Vm < Serializers::Base
  def self.base(vm)
    {
      id: vm.ubid,
      name: vm.name,
      state: vm.display_state,
      location: vm.display_location,
      size: vm.display_size,
      unix_user: vm.unix_user,
      storage_size_gib: vm.storage_size_gib,
      ip6: vm.ephemeral_net6&.nth(2),
      ip4: vm.ephemeral_net4
    }
  end

  structure(:default) do |vm|
    base(vm)
  end

  structure(:detailed) do |vm|
    base(vm).merge(
      firewalls: vm.firewalls.map { |fw| Serializers::Api::Firewall.serialize(fw) },
      private_ipv4: vm.nics.first.private_ipv4.network,
      private_ipv6: vm.nics.first.private_ipv6.nth(2),
      subnet: vm.nics.first.private_subnet.name
    )
  end
end
