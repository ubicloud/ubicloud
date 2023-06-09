# frozen_string_literal: true

require_relative "../base"

class Serializers::Web::VmHost < Serializers::Base
  def self.base(vmh)
    {
      id: vmh.id,
      ulid: vmh.ulid,
      host: vmh.sshable.host,
      state: vmh.allocation_state,
      location: vmh.location,
      ip6: vmh.ip6,
      vms_count: vmh.vms.count,
      total_cores: vmh.total_cores,
      used_cores: vmh.used_cores,
      public_keys: vmh.sshable.keys.map(&:public_key),
      ndp_needed: vmh.ndp_needed
    }
  end

  structure(:default) do |vhm|
    base(vhm)
  end

  structure(:detail) do |vhm|
    ret = base(vhm)

    ret.merge({
      vms: Serializers::Web::Vm.new(:default).serialize(vhm.vms)
    })
  end
end
