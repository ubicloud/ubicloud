# frozen_string_literal: true

class Serializers::KubernetesCluster < Serializers::Base
  def self.serialize_internal(kc, options = {})
    base = {
      id: kc.ubid,
      name: kc.name,
      location: kc.location.display_name,
      display_state: kc.display_state,
      cp_node_count: kc.cp_node_count,
      node_size: kc.target_node_size,
      version: kc.version
    }
    if options[:detailed]
      base[:cp_vms] = Serializers::Vm.serialize(kc.cp_vms_via_nodes_dataset.all)
      base[:nodepools] = Serializers::KubernetesNodepool.serialize(kc.nodepools_dataset.all, {detailed: true})
    end
    base
  end
end
