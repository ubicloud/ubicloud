# frozen_string_literal: true

class Serializers::KubernetesCluster < Serializers::Base
  def self.serialize_internal(kc, options = {})
    {
      id: kc.ubid,
      name: kc.name,
      subnet: kc.subnet,
      kubernetes_version: kc.kubernetes_version,
      location: kc.location
    }
  end
end
