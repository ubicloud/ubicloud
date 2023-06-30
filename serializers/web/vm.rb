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
      storage_size_gib: vm.storage_size_gib,
      ip6: vm.ephemeral_net6&.nth(2),
      projects: Serializers::Web::Project.new(:default).serialize(vm.projects)
    }
  end

  structure(:default) do |vm|
    base(vm)
  end
end
