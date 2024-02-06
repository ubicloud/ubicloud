# frozen_string_literal: true

require_relative "../base"

class Serializers::Api::Vm < Serializers::Base
  def self.base(vm)
    {
      id: vm.ubid,
      name: vm.name,
      state: vm.display_state,
      location: vm.location,
      display_size: vm.display_size,
      unix_user: vm.unix_user,
      ip6: vm.ephemeral_net6&.nth(2),
      ip4: vm.ephemeral_net4
    }
  end

  structure(:default) do |vm|
    base(vm)
  end
end
