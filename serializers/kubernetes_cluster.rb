# frozen_string_literal: true

class Serializers::KubernetesCluster < Serializers::Base
  def self.serialize_internal(kc, options = {})
    base = {
      id: kc.ubid,
      name: kc.name,
      state: kc.display_state,
      cp_node_count: kc.cp_node_count,
      private_subnet_id: kc.private_subnet_id,
      version: kc.version,
      location: kc.display_location,
      cp_vms: kc.cp_vms.map { |vm| {name: vm.name, state: vm.display_state, hostname: vm.ephemeral_net4.to_s} },
      nodepools: kc.nodepools_dataset.eager(:vms).map { |np| {name: np.name, node_count: np.node_count, vms: np.vms.map { |vm| {name: vm.name, state: vm.display_state, hostname: vm.ephemeral_net4.to_s} }} }
    }

    if options[:include_path]
      base[:path] = kc.path
    end

    base
  end
end
