# frozen_string_literal: true

class Serializers::KubernetesCluster < Serializers::Base
  def self.serialize_internal(kc, options = {})
    base = {
      id: kc.ubid,
      name: kc.name,
      replica: kc.replica,
      private_subnet_id: kc.private_subnet_id,
      kubernetes_version: kc.kubernetes_version,
      location: kc.location
    }

    if options[:include_path]
      base[:path] = kc.path
    end

    base
  end
end
