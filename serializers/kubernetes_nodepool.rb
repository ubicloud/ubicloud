# frozen_string_literal: true

class Serializers::KubernetesNodepool < Serializers::Base
  def self.serialize_internal(kn, options = {})
    base = {
      id: kn.ubid,
      kubernetes_cluster_id: kn.cluster.ubid,
      name: kn.name,
      node_count: kn.node_count,
      node_size: kn.target_node_size
    }
    if options[:detailed]
      base[:vms] = Serializers::Vm.serialize(kn.vms_via_nodes_dataset.all)
    end
    base
  end
end
