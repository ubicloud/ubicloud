# frozen_string_literal: true

class Serializers::KubernetesVm < Serializers::Base
  def self.serialize_internal(kv, options = {})
    Serializers::Vm.serialize(kv.vm)
  end
end
