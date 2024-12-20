# frozen_string_literal: true

class Serializers::KubernetesCluster < Serializers::Base
  def self.serialize_internal(kc, options = {})
    base = {
      id: kc.ubid,
      name: kc.name,
      replica: kc.replica,
      private_subnet_id: kc.private_subnet_id,
      kubernetes_version: kc.kubernetes_version,
      location: kc.display_location,
      vms: kc.vms.map { |vm| {name: vm.name, state: vm.display_state} },
      nodepools: kc.kubernetes_nodepools.map { |np| {name: np.name, replicas: np.replica, kubernetes_version: np.kubernetes_version, vms: np.vms.map { |vm| {name: vm.name, state: vm.display_state} }} }
    }

    if options[:include_path]
      base[:path] = kc.path
    end

    base
  end
end
