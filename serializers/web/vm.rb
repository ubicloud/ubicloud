# frozen_string_literal: true

require_relative "../base"

class Serializers::Web::Vm < Serializers::Base
  def self.base(vm)
    {
      id: vm.id,
      ulid: vm.ulid,
      path: vm.path,
      name: vm.name,
      state: vm.display_state,
      location: vm.location,
      size: vm.size,
      ip6: vm.ephemeral_net6&.nth(2),
      tag_spaces: Serializers::Web::TagSpace.new(:default).serialize(vm.tag_spaces)
    }
  end

  structure(:default) do |vm|
    base(vm)
  end
end
