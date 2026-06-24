# frozen_string_literal: true

class Serializers::KubernetesNodepool < Serializers::Base
  VMS_EAGER = [:strand, :semaphores, :assigned_vm_address, :vm_storage_volumes, :location].freeze

  def self.serialize_internal(kn, options = {})
    base = {
      id: kn.ubid,
      kubernetes_cluster_id: kn.cluster.ubid,
      name: kn.name,
      node_count: kn.node_count,
      node_size: kn.target_node_size,
    }
    if options[:detailed]
      base[:vms] = Serializers::Vm.serialize(kn.vms(eager: VMS_EAGER))
    end
    base
  end
end
