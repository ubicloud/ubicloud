# frozen_string_literal: true

class Serializers::Vm < Serializers::Base
  def self.serialize_internal(vm, options = {})
    base = {
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

    if options[:include_path]
      base[:path] = vm.path
    end

    if options[:detailed]
      base.merge!(
        firewalls: Serializers::Firewall.serialize(vm.firewalls),
        private_ipv4: vm.nics.first.private_ipv4.network,
        private_ipv6: vm.nics.first.private_ipv6.nth(2),
        subnet: vm.nics.first.private_subnet.name
      )
    end

    if options[:load_balancer]
      base[:load_balancer_state] = vm.load_balancers_vms.state
    end

    base
  end
end
