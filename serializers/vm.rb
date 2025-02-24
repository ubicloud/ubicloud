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
      ip4_enabled: vm.ip4_enabled,
      ip4: vm.ephemeral_net4
    }

    if options[:include_path]
      base[:path] = vm.path
    end

    if options[:detailed]
      base.merge!(
        firewalls: Serializers::Firewall.serialize(vm.firewalls, {include_path: true}),
        private_ipv4: vm.private_ipv4,
        private_ipv6: vm.private_ipv6,
        subnet: vm.nics.first.private_subnet.name
      )
    end

    if options[:load_balancer]
      base[:load_balancer_state] = vm.load_balancer_ports.first&.state
    end

    base
  end
end
