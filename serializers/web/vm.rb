# frozen_string_literal: true

class Serializers::Web::Vm < Serializers::Base
  def self.base(vm)
    {
      id: vm.id,
      ubid: vm.ubid,
      path: vm.path,
      name: vm.name,
      state: vm.display_state,
      location: vm.display_location,
      display_size: vm.display_size,
      storage_size_gib: vm.storage_size_gib,
      storage_encryption: vm.storage_encrypted? ? "encrypted" : "not encrypted",
      ip6: vm.ephemeral_net6&.nth(2),
      ip4: vm.ephemeral_net4,
      unix_user: vm.unix_user
    }
  end

  structure(:default) do |vm|
    base(vm)
  end

  structure(:detailed) do |vm|
    base(vm).merge(
      firewalls: vm.firewalls.map { |fw| Serializers::Web::Firewall.serialize(fw) },
      private_ip4: vm.nics.first.private_ipv4.network,
      private_ip6: vm.nics.first.private_ipv6.nth(2),
      subnet: vm.nics.first.private_subnet.name
    )
  end
end
